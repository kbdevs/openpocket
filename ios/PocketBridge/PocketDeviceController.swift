import Foundation
import CoreBluetooth
import Network
import NetworkExtension
import Observation

struct PocketPeripheral: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}


@MainActor @Observable
final class PocketDeviceController: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private(set) var devices: [PocketPeripheral] = []
    private(set) var files: [DeviceRecording] = []
    private(set) var scanning = false
    private(set) var connected = false
    private(set) var authenticated = false
    private(set) var reconnecting = false
    private(set) var busy = false
    private(set) var status = "Ready to scan"
    private(set) var deviceName = "Pocket"
    private(set) var battery: Int?
    private(set) var batteryStatus: String?
    private(set) var firmware = ""
    private(set) var wifiFirmware = ""
    private(set) var received = 0
    private(set) var expected = 0
    private(set) var completedFiles = 0
    private(set) var totalFiles = 0
    private(set) var recordingOnDevice = false
    private(set) var storageFreeMB: Int?
    private(set) var storageTotalMB: Int?
    private(set) var live: LiveTranscriber?
    /// Recordings listed on Pocket that are not on this iPhone yet.
    var newOnPocket: Int { files.filter { !imported($0) }.count }
    var error: String?
    var preferWiFi = UserDefaults.standard.object(forKey: "pocket.preferWiFi") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferWiFi, forKey: "pocket.preferWiFi") }
    }
    var autoSync = UserDefaults.standard.bool(forKey: "pocket.autoSync") {
        didSet { UserDefaults.standard.set(autoSync, forKey: "pocket.autoSync") }
    }
    private(set) var rememberedDevice = PocketRememberedDevice.load()
    var onImport: ((UUID) -> Void)?
    private var autoConnectPaused = false
    private var connectWhenPoweredOn = false
    private let library: LibraryStore
    private let pairingKeys = PocketPairingKeyStore()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var replies: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var batteryLevelCharacteristic: CBCharacteristic?
    private var batteryReadings = PocketBatteryReadings()
    private var batteryReadRequested = false
    private var lowBatteryNotified = false
    private var notified = Set<String>()
    private var history: [(Int, PocketProtocol.Message)] = []
    private var serial = 0
    private var output: FileHandle?
    private var transferError: Error?
    private var lastByteAt = ContinuousClock.now
    private var receivingBLE = false
    private var connectionTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var connectionID = UUID()
    private var operationID = UUID()
    private var activeOperationID: UUID?
    private var setupBusy = false
    private var operationBusy = false
    private var sessionAccepted = false
    private var connectionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var heartbeat: Task<Void, Never>?
    private var batteryPoll: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var scanStarted = false
    private var awaitingPairingDisconnect = false
    private var link = PocketLinkLifecycle()
    private var setupStep = "Connecting to Pocket"
    private(set) var connectionLog: [String] = []
    var connectionReport: String {
        (["OpenPocket connection report", "No pairing keys, Wi-Fi passwords or audio are included."] + connectionLog).joined(separator: "\n")
    }
    private var wifiSSID: String?
    private var wifiRaised = false
    private var socket: NWConnection?
    private var linkError: Error?

    init(library: LibraryStore) {
        self.library = library
        super.init()
        // Create CoreBluetooth only after the user opens the device screen or scans.
    }

    func scan() {
        guard connectionTask == nil else { return }
        devices = []; error = nil; scanning = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        switch central.state {
        case .poweredOn: beginScan()
        case .poweredOff: status = "Turn on Bluetooth in iPhone Settings"
        case .unauthorized: status = "Allow Bluetooth access in iPhone Settings"
        case .unsupported: scanning = false; status = "Bluetooth is not available on this device"
        default: status = "Waiting for Bluetooth"
        }
    }

    private func beginScan() {
        guard scanning, !scanStarted, central?.state == .poweredOn else { return }
        scanStarted = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        status = "Looking for your Pocket"
        scanTimeout?.cancel()
        scanTimeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            if self.scanning { self.stopScan() }
        }
    }

    func stopScan() {
        pauseScan()
        scanning = false
        if !connected { status = devices.isEmpty ? "No Pocket found. Close the vendor app and wake the recorder." : "Choose your Pocket" }
    }

    private func pauseScan() {
        scanTimeout?.cancel(); scanTimeout = nil
        if scanStarted { central?.stopScan(); scanStarted = false }
    }

    func pair(_ device: PocketPeripheral) {
        guard !busy, connectionTask == nil else { return }
        error = nil
        do {
            try PocketPairingKeyStore.startPairing(
                for: device.id,
                keyFor: { try self.pairingKeys.key(for: $0) },
                startConnection: { key in self.startConnection(device, key: key, pairing: true) }
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect(_ device: PocketPeripheral, key: String) {
        guard !busy, connectionTask == nil else { return }
        guard PocketProtocol.validKey(key) else {
            error = "Enter the current 16-character Pocket session key."
            return
        }
        startConnection(device, key: key, pairing: false)
    }

    /// Reconnects to the paired Pocket with its saved key. Called on launch and on return to the app.
    func connectRemembered(userInitiated: Bool = false) {
        if userInitiated { autoConnectPaused = false; error = nil }
        guard !autoConnectPaused, !scanning, !busy, connectionTask == nil, !connected else { return }
        let legacyID = rememberedDevice == nil ? pairingKeys.lastPairedDeviceID() : nil
        guard rememberedDevice != nil || legacyID != nil else { return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        guard central.state == .poweredOn else {
            // centralManagerDidUpdateState retries once Bluetooth is ready.
            connectWhenPoweredOn = true
            if let name = rememberedDevice?.name { deviceName = name }
            return
        }
        connectWhenPoweredOn = false
        if let legacyID, let peripheral = central.retrievePeripherals(withIdentifiers: [legacyID]).first {
            remember(PocketPeripheral(peripheral: peripheral, name: peripheral.name ?? "Pocket", rssi: 0))
        }
        guard let saved = rememberedDevice else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [saved.id]).first else {
            status = "Wake your Pocket, then tap Connect"
            return
        }
        let key: String
        do {
            guard let savedKey = try pairingKeys.savedKey(for: saved.id) else {
                error = "The pairing key for \(saved.name) is missing. Forget this Pocket and pair again."
                return
            }
            key = savedKey
        } catch {
            self.error = error.localizedDescription
            return
        }
        startConnection(PocketPeripheral(peripheral: peripheral, name: saved.name, rssi: 0), key: key, pairing: false, resume: true)
    }

    /// Stops auto-connect for this app session. The paired Pocket is kept for the next launch.
    func userDisconnect() {
        autoConnectPaused = true
        disconnect()
    }

    func forgetRememberedDevice() {
        autoConnectPaused = true
        disconnect()
        PocketRememberedDevice.forget()
        rememberedDevice = nil
        status = "Ready to scan"
    }

    private func remember(_ device: PocketPeripheral) {
        Notifier.requestPermission()
        // Pairing the same Pocket again keeps its nickname.
        let name = rememberedDevice?.id == device.id ? rememberedDevice?.name ?? device.name : device.name
        deviceName = name
        let saved = PocketRememberedDevice(id: device.id, name: name)
        guard saved != rememberedDevice else { return }
        saved.save()
        rememberedDevice = saved
    }

    /// Sets the name the app shows. Pocket's own Bluetooth name does not change.
    func renameRemembered(_ newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = rememberedDevice, !name.isEmpty, name.count <= 40 else { return }
        let saved = PocketRememberedDevice(id: current.id, name: name)
        saved.save()
        rememberedDevice = saved
        deviceName = name
    }

    /// `resume` skips the first setup and lets the reconnect loop connect, so a sleeping
    /// or out-of-range Pocket is retried with backoff instead of failing.
    private func startConnection(_ device: PocketPeripheral, key: String, pairing: Bool, resume: Bool = false) {
        guard !busy, connectionTask == nil else { return }
        stopScan()
        autoConnectPaused = false; connectWhenPoweredOn = false
        command = nil; replies = nil; audio = nil; batteryLevelCharacteristic = nil
        notified = []; history = []; authenticated = false; sessionAccepted = resume; reconnecting = resume
        linkError = nil; transferError = nil
        clearBattery()
        deviceName = device.name; setupBusy = !resume; updateBusy(); error = nil; connectionLog = []
        if resume { status = "Connecting to \(device.name)" }
        let attemptID = UUID()
        connectionID = attemptID
        batteryPoll?.cancel()
        batteryPoll = Task {
            // The reply is parsed in didUpdateValueFor, so no wait is needed here.
            while connectionID == attemptID {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if authenticated, connected, !busy { try? send("BAT") }
            }
        }
        connectionTask = Task {
            defer {
                if connectionID == attemptID {
                    setupBusy = false; reconnecting = false; connectionTask = nil; updateBusy()
                }
            }
            do {
                if !resume {
                    try await self.establish(device, key: key, pairing: pairing)
                    try Task.checkCancellation()
                    guard connectionID == attemptID else { throw CancellationError() }
                    awaitingPairingDisconnect = false
                    sessionAccepted = true
                    authenticated = connected && link.isConnected
                    reconnecting = !authenticated
                    if !pairing {
                        do {
                            try pairingKeys.remember(key, for: device.id)
                            try Keychain.set(key, for: "pocket-session")
                        } catch {
                            self.error = "Pocket connected, but the pairing key could not be saved."
                        }
                    }
                    remember(device)
                    setSetupStep("Reading Pocket information")
                    readBatteryLevel()
                    await readDeviceInfo(sessionID: attemptID)
                    try Task.checkCancellation()
                    guard connectionID == attemptID else { throw CancellationError() }
                    if connected { status = "Connected" }
                    else { reconnecting = true; status = "Reconnecting to Pocket" }
                    setupBusy = false; updateBusy()
                }
                try await PocketReconnectLoop.run(
                    key: key,
                    isBluetoothOn: { self.central?.state == .poweredOn },
                    waitForSessionEnd: { try await self.waitForReconnect(sessionID: attemptID) },
                    waitForBluetoothOn: { try await self.waitForBluetoothOn() },
                    waitForLinkDrain: { try await self.waitForLinkDrain() },
                    closeLink: { if self.connectionID == attemptID { self.closeCurrentLink() } },
                    connect: { savedKey, reconnectPairing in
                        try Task.checkCancellation()
                        guard self.connectionID == attemptID else { throw CancellationError() }
                        self.setupBusy = true; self.updateBusy(); self.error = nil
                        defer {
                            if self.connectionID == attemptID { self.setupBusy = false; self.updateBusy() }
                        }
                        try await self.establish(device, key: savedKey, pairing: reconnectPairing)
                        try Task.checkCancellation()
                        guard self.connectionID == attemptID else { throw CancellationError() }
                        self.awaitingPairingDisconnect = false
                        guard self.connected, self.link.isConnected else {
                            self.authenticated = false; self.reconnecting = true
                            self.status = "Reconnecting to Pocket"
                            throw self.linkError ?? PocketError.message("Pocket disconnected after accepting the key.")
                        }
                        self.authenticated = true
                        self.reconnecting = false
                        self.readBatteryLevel()
                        await self.readDeviceInfo(sessionID: attemptID)
                        try Task.checkCancellation()
                        guard self.connectionID == attemptID else { throw CancellationError() }
                        guard self.connected else { throw self.linkError ?? PocketError.message("Pocket disconnected during setup.") }
                        self.status = "Connected"
                    },
                    pause: { delay in try await Task.sleep(for: delay) }
                )
            } catch is CancellationError {
                guard connectionID == attemptID else { return }
                disconnect()
            } catch {
                guard connectionID == attemptID else { return }
                self.error = "\(setupStep): \(error.localizedDescription)"
                trace("Setup stopped at: \(setupStep)")
                self.disconnect()
            }
        }
    }

    private func establish(_ device: PocketPeripheral, key: String, pairing: Bool) async throws {
        try await PocketHandshake.establish(
            key: key, pairing: pairing,
            open: { try await self.openPairingLink(device) },
            authenticate: { savedKey in
                self.setSetupStep("Checking the saved pairing key")
                let reply = try await self.request("SK&\(savedKey)", type: "SK")
                return reply.value == "OK"
            },
            close: { try await self.closePairingLink(device.peripheral) },
            pause: {
                self.setSetupStep("Waiting for Pocket to restart its connection")
                try await Task.sleep(for: .seconds(2))
            }
        )
    }

    private func readDeviceInfo(sessionID: UUID) async {
        for (command, reply) in [("BAT", "BAT"), ("FW", "FW"), ("WF", "WF"), ("SPACE", "SPA")] {
            guard connectionID == sessionID, !Task.isCancelled, connected else { return }
            _ = try? await request(command, type: reply)
        }
        afterConnect()
    }

    /// Lists recordings after each connection so new ones are counted, and syncs them when auto sync is on.
    private func afterConnect() {
        Task {
            while setupBusy { try? await Task.sleep(for: .milliseconds(200)) }
            syncNewRecordings()
        }
    }

    private func syncNewRecordings() {
        guard authenticated, !busy, !recordingOnDevice else { return }
        run {
            try await self.loadFiles()
            guard self.autoSync else { self.status = "Connected"; return }
            let pending = self.files.filter { !self.imported($0) }
            guard !pending.isEmpty else { self.status = "Connected"; return }
            self.totalFiles = pending.count
            for file in pending {
                try await self.download(file, wifi: false)
                self.completedFiles += 1
            }
            self.status = "New recordings saved to iPhone"
        }
    }

    // Experimental: the vendor app names STA and STO, but their effect from the app is not confirmed.
    func startRecording() { guard authenticated, !busy else { return }; try? send("STA") }
    func stopRecording() { guard authenticated, !busy else { return }; try? send("STO") }

    private func startLiveTranscript() {
        live?.cancel()
        live = LiveTranscriber(deepgramKey: AIConfiguration.key(AIConfiguration.deepgramAccount, bundledName: "DEEPGRAM_API_KEY"))
        guard live != nil, let audio, !audio.isNotifying else { return }
        peripheral?.setNotifyValue(true, for: audio)
    }

    private func updateBusy() { busy = setupBusy || operationBusy }

    private func clearBattery() {
        batteryReadings.reset(); batteryReadRequested = false; battery = nil; batteryStatus = nil
    }

    private func updateBattery() {
        battery = batteryReadings.value
        // Same 20% threshold as the vendor app. Notify once per drop.
        if let battery, battery <= 20, !lowBatteryNotified {
            lowBatteryNotified = true
            Notifier.post(id: "pocket-battery-low", title: "Pocket battery low", body: "\(deviceName) is at \(battery)%. Charge it soon.")
        } else if let battery, battery > 25 {
            lowBatteryNotified = false
        }
        batteryStatus = nil
        if batteryReadings.differ, let vendor = batteryReadings.vendor, let standard = batteryReadings.standard {
            trace("Battery conflict: vendor \(vendor)%, standard \(standard)%")
        }
    }

    private func readBatteryLevel() {
        guard authenticated, let characteristic = batteryLevelCharacteristic,
              characteristic.properties.contains(.read), !batteryReadRequested else { return }
        batteryReadRequested = true
        peripheral?.readValue(for: characteristic)
    }

    private func signalConnectionChange() {
        let waiters = Array(connectionWaiters.values)
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForConnectionChange() async {
        let id = UUID()
        await withCheckedContinuation { connectionWaiters[id] = $0 }
    }

    private func waitForSessionEnd() async throws {
        while link.isConnected && central?.state == .poweredOn {
            try Task.checkCancellation()
            await waitForConnectionChange()
        }
    }

    private func waitForReconnect(sessionID: UUID) async throws {
        try await waitForSessionEnd()
        try Task.checkCancellation()
        guard connectionID == sessionID else { throw CancellationError() }
        reconnecting = true; setupBusy = false; updateBusy()
        await stopOperationAndWait()
        try Task.checkCancellation()
        guard connectionID == sessionID else { throw CancellationError() }
        reconnecting = true
        status = central?.state == .poweredOn ? "Reconnecting to Pocket" : "Bluetooth is off. Reconnecting when it is back on"
    }

    private func waitForBluetoothOn() async throws {
        while central?.state != .poweredOn {
            try Task.checkCancellation()
            await waitForConnectionChange()
        }
    }

    private func waitForLinkDrain() async throws {
        while link.isPending {
            try Task.checkCancellation()
            await waitForConnectionChange()
        }
    }

    private func closeCurrentLink() {
        guard let peripheral, link.beginClosing() else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    private func stopOperationAndWait() async {
        guard let operation else { return }
        operation.cancel(); socket?.cancel()
        await operation.value
    }

    private func setSetupStep(_ step: String) {
        setupStep = step; status = step; trace(step)
    }

    private func trace(_ text: String) {
        connectionLog.append(text)
        if connectionLog.count > 80 { connectionLog.removeFirst() }
    }

    private func openPairingLink(_ device: PocketPeripheral) async throws {
        try Task.checkCancellation()
        if let previous = peripheral, link.isPending { try await closePairingLink(previous) }
        try Task.checkCancellation()
        command = nil; replies = nil; audio = nil; batteryLevelCharacteristic = nil
        notified = []; history = []; clearBattery()
        linkError = nil; transferError = nil
        connected = false; authenticated = false
        setSetupStep("Connecting to Pocket")
        awaitingPairingDisconnect = false
        peripheral = device.peripheral
        device.peripheral.delegate = self
        try link.beginConnection()
        central.connect(device.peripheral)
        try await wait(timeout: 25, requireConnection: false) {
            self.connected && self.command != nil && self.notified.contains(PocketProtocol.reply)
        }
    }

    private func closePairingLink(_ device: CBPeripheral) async throws {
        try Task.checkCancellation()
        awaitingPairingDisconnect = true
        linkError = nil; transferError = nil
        guard link.isPending else { connected = false; return }
        setSetupStep("Closing the first pairing connection")
        if link.beginClosing() { central.cancelPeripheralConnection(device) }
        try await wait(timeout: 12, requireConnection: false) { !self.link.isPending }
    }

    func disconnect() {
        connectionID = UUID(); operationID = UUID()
        sessionAccepted = false; reconnecting = false; setupBusy = false
        awaitingPairingDisconnect = false
        connectionTask?.cancel(); connectionTask = nil
        operation?.cancel()
        heartbeat?.cancel(); heartbeat = nil
        batteryPoll?.cancel(); batteryPoll = nil
        live?.cancel(); live = nil; recordingOnDevice = false
        socket?.cancel(); socket = nil
        if wifiRaised && connected { try? send("WIFIC") }
        wifiRaised = false
        closeCurrentLink()
        connected = false; authenticated = false; batteryLevelCharacteristic = nil; status = "Disconnected"
        if let wifiSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: wifiSSID) }
        wifiSSID = nil; receivingBLE = false; clearBattery(); updateBusy(); signalConnectionChange()
    }


    func refresh(date: Date? = nil) {
        run {
            try await self.loadFiles(date: date)
            self.status = "\(self.files.count) recordings on Pocket"
        }
    }

    func refreshBattery() {
        guard authenticated, connected, !busy else { return }
        clearBattery()
        run {
            self.readBatteryLevel()
            _ = try? await self.request("BAT", type: "BAT")
        }
    }

    private func loadFiles(date: Date? = nil) async throws {
        status = "Reading recording dates"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.locale = Locale(identifier: "en_US_POSIX")
        var dates: [String]
        if let date { dates = [formatter.string(from: date)] }
        else {
            let mark = serial
            let summary = try await request("LIST_DIRS", type: "DIRS_SUM", timeout: 15)
            let entries = messages(after: mark, type: "DIRS")
            guard let result = PocketProtocol.directoryDates(entries, summary: summary) else { throw PocketError.message("The recorder returned an incomplete date list. Try again or choose a date.") }
            dates = result
        }
        var listed: [DeviceRecording] = date == nil ? [] : files.filter { !dates.contains($0.date) }
        for date in dates {
            try Task.checkCancellation()
            status = "Reading \(date)"
            let mark = serial
            let summary = try await request("LIST&\(date)", type: "LIST", timeout: 20)
            let entries = messages(after: mark, type: "F")
            guard let recordings = PocketProtocol.recordings(entries, summary: summary, date: date) else { throw PocketError.message("The recorder returned an incomplete file list for \(date). Try again.") }
            listed += recordings
        }
        files = listed.sorted { $0.id > $1.id }
    }

    func sync(_ selected: [DeviceRecording], wifi requested: Bool) {
        guard !recordingOnDevice else { error = "Stop the recording on Pocket before you sync files."; return }
        // Same rule as the vendor app: Wi-Fi transfer needs more than 10% battery.
        let wifi = requested && (battery ?? 100) > 10
        run {
            if requested && !wifi { self.status = "Battery is under 10%. Using Bluetooth." }
            self.totalFiles = selected.count; self.completedFiles = 0
            for file in selected {
                try Task.checkCancellation()
                try await self.download(file, wifi: wifi)
                self.completedFiles += 1
            }
            self.status = "\(self.completedFiles) recordings saved to iPhone"
        }
    }

    func cancel() {
        if operation != nil {
            PocketSessionTaskControl.stopTransfer(operation) {
                self.socket?.cancel()
            }
            return
        }
        if connectionTask != nil { disconnect() }
    }
    func imported(_ file: DeviceRecording) -> Bool { library.recordings.contains { $0.deviceFileID == fingerprint(file) } }
    private func fingerprint(_ file: DeviceRecording) -> String { "\(peripheral?.identifier.uuidString ?? deviceName)/\(file.id)/\(file.duration)" }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard authenticated, !busy else { return }
        operationBusy = true; updateBusy(); error = nil
        received = 0; expected = 0; completedFiles = 0; totalFiles = 0
        let operationID = UUID()
        self.operationID = operationID
        activeOperationID = operationID
        operation = Task {
            defer {
                if self.activeOperationID == operationID {
                    self.activeOperationID = nil; self.operationBusy = false
                    self.operation = nil; self.receivingBLE = false; self.updateBusy()
                }
            }
            do { try await work() }
            catch is CancellationError {
                guard self.operationID == operationID else { return }
                status = connected ? "Sync stopped. Device recordings were kept." : "Pocket disconnected"
            }
            catch {
                guard self.operationID == operationID else { return }
                self.error = error.localizedDescription; status = "Action stopped"
            }
        }
    }

    private func download(_ file: DeviceRecording, wifi: Bool) async throws {
        guard PocketProtocol.validDate(file.date), PocketProtocol.safeName(file.name) else { throw PocketError.message("Invalid recording name.") }
        let partial = URL.temporaryDirectory.appendingPathComponent("pocket-\(UUID().uuidString).part")
        let finished = partial.deletingPathExtension().appendingPathExtension("mp3")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw PocketError.message("Cannot create a temporary Pocket recording file.") }
        received = 0; expected = 0; transferError = nil; lastByteAt = .now
        defer {
            try? output?.close(); output = nil; receivingBLE = false
            socket?.cancel(); socket = nil
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: finished)
        }
        output = try FileHandle(forWritingTo: partial)
        do {
            // Wi-Fi starts with a BLE transfer, so its initial audio needs a subscriber too.
            try await enableAudioNotifications()
            if wifi { try await startWiFi() }
            status = "Syncing \(file.name) over \(wifi ? "Wi-Fi" : "Bluetooth")"
            if wifi { try await openSocket() }
            let mark = serial
            receivingBLE = !wifi
            let reply = try await request("U&\(file.date)&\(file.name)", type: "U", timeout: 10)
            guard let size = PocketProtocol.size(reply) else { throw PocketError.message("The recorder returned an invalid file size.") }
            expected = size
            if wifi {
                // The TCP connection is ready before this switch. Otherwise firmware can hang.
                try await Task.sleep(for: .milliseconds(300))
                let switchMark = serial
                try send("U&WIFI")
                let (ackSerial, _) = try await waitForMessage(after: switchMark, type: "U", timeout: 10) { $0.fields == ["WIFI"] }
                let (_, resumedSize) = try await waitForMessage(after: ackSerial, type: "U", timeout: 10) { PocketProtocol.size($0) != nil }
                guard PocketProtocol.size(resumedSize) == size else { throw PocketError.message("Pocket changed the recording size during the Wi-Fi switch.") }
                try await receiveWiFi(size: size)
            } else {
                try await wait(timeout: max(30, Double(size) / 1000 + 30)) {
                    if self.transferError != nil { return true }
                    return self.received >= size && !self.messages(after: mark, type: "OFF").isEmpty
                }
                if let error = transferError { throw error }
                guard received == size else { throw PocketError.message("Bluetooth file size mismatch: \(received) of \(size) bytes. Try Wi-Fi sync.") }
            }
            if wifi { socket?.cancel(); socket = nil }
            try output?.synchronize(); try output?.close(); output = nil; receivingBLE = false
            try FileManager.default.moveItem(at: partial, to: finished)
            // Import only after the device byte count has been checked.
            let id = try await library.importAudio(finished, title: "Pocket recording", origin: wifi ? "Pocket · Wi-Fi" : "Pocket · Bluetooth")
            try library.update(id) { $0.deviceFileID = self.fingerprint(file) }
            onImport?(id)
            if wifi { await stopWiFi() }
        } catch {
            if wifi { await stopWiFi() }
            throw error
        }
    }

    private func enableAudioNotifications() async throws {
        guard let audio, audio.properties.contains(.notify) || audio.properties.contains(.indicate) else {
            throw PocketError.message("Pocket did not expose a recording notification channel.")
        }
        if audio.isNotifying { notified.insert(PocketProtocol.audio) }
        else { peripheral?.setNotifyValue(true, for: audio) }
        try await wait(timeout: 12) { self.notified.contains(PocketProtocol.audio) }
    }

    private func send(_ command: String) throws {
        guard connected, let peripheral, let characteristic = self.command else { throw PocketError.message("Pocket is disconnected.") }
        let data = Data("APP&\(command)".utf8)
        let mode: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let maximum = peripheral.maximumWriteValueLength(for: mode)
        guard data.count <= maximum else { throw PocketError.message("This command exceeds the Bluetooth packet size.") }
        if mode == .withoutResponse && !peripheral.canSendWriteWithoutResponse { throw PocketError.message("Bluetooth is busy. Try again.") }
        trace("TX \(command.components(separatedBy: "&")[0]) (\(data.count)/\(maximum) bytes, \(mode == .withResponse ? "write request" : "write command"))")
        peripheral.writeValue(data, for: characteristic, type: mode)
    }
    private func request(_ command: String, type: String, timeout: Double = 8, accept: (PocketProtocol.Message) -> Bool = { _ in true }) async throws -> PocketProtocol.Message {
        let mark = serial
        try send(command)
        let (_, reply) = try await waitForMessage(after: mark, type: type, timeout: timeout, accept: accept)
        return reply
    }

    private func waitForMessage(after mark: Int, type: String, timeout: Double, accept: (PocketProtocol.Message) -> Bool) async throws -> (Int, PocketProtocol.Message) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let reply = history.first(where: { $0.0 > mark && $0.1.type == type && accept($0.1) }) { return reply }
            guard connected else { throw PocketError.message("Pocket disconnected while waiting for \(type).") }
            if let linkError { throw linkError }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PocketError.message("Pocket did not answer \(type). Try the action again.")
    }
    private func messages(after mark: Int, type: String) -> [PocketProtocol.Message] { history.filter { $0.0 > mark && $0.1.type == type }.map(\.1) }
    private func wait(timeout: Double, requireConnection: Bool = true, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            try Task.checkCancellation()
            if requireConnection && !connected { throw PocketError.message("Pocket disconnected.") }
            if let linkError { throw linkError }
            if let transferError { throw transferError }
            if condition() { return }
            if output != nil && expected > 0 && ContinuousClock.now - lastByteAt > .seconds(20) { throw PocketError.message("The transfer stopped receiving data. Your device recording was kept.") }
            guard ContinuousClock.now < deadline else { throw PocketError.message("Pocket did not complete the action in time.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func startWiFi() async throws {
        status = "Starting Pocket Wi-Fi"
        // ponytail: one file per AP session works on 1.7 and 1.8; reuse sessions after hardware tests.
        wifiRaised = true
        _ = try await request("WIFIO", type: "WIFIO")
        heartbeat = Task {
            while !Task.isCancelled {
                try? send("WPING")
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        let reply = try await request("WIFI", type: "WIFI")
        guard let credentials = PocketProtocol.wifiCredentials(reply) else { throw PocketError.message("Pocket returned invalid Wi-Fi credentials.") }
        wifiSSID = credentials.ssid
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var available = false
        while ContinuousClock.now < deadline {
            let state = try await request("WIFIS", type: "WIFIS", timeout: 3).value
            if state == "2" || state == "1" { available = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        guard available else { throw PocketError.message("Pocket Wi-Fi did not become ready.") }
        status = "Joining Pocket Wi-Fi"
        let config = NEHotspotConfiguration(ssid: credentials.ssid, passphrase: credentials.password, isWEP: false)
        config.hidden = true
        config.joinOnce = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                if let error = error as NSError?, error.code != NEHotspotConfigurationError.alreadyAssociated.rawValue { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let joinedDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < joinedDeadline {
            if try await request("WIFIS", type: "WIFIS", timeout: 3).value == "1" { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw PocketError.message("Pocket did not confirm the Wi-Fi connection.")
    }

    private func stopWiFi() async {
        heartbeat?.cancel(); heartbeat = nil; socket?.cancel(); socket = nil
        if wifiRaised && connected {
            // A canceled sync still needs to lower the AP before it leaves BLE.
            let closing = Task { try? await self.request("WIFIC", type: "WIFIC", timeout: 5) }
            _ = await closing.value
        }
        wifiRaised = false
        if let wifiSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: wifiSSID) }
        wifiSSID = nil
    }


    private func openSocket() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(PocketProtocol.wifiHost), port: NWEndpoint.Port(rawValue: PocketProtocol.wifiPort)!, using: parameters)
        socket = connection
        var ready = false
        var failure: Error?
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state { case .ready: ready = true; case .failed(let error): failure = error; case .cancelled: failure = CancellationError(); default: break }
            }
        }
        connection.start(queue: .main)
        try await wait(timeout: 15) { ready || failure != nil }
        if let failure { throw failure }
        guard let path = connection.currentPath, path.usesInterfaceType(.wifi),
              case .hostPort(let host, _) = path.localEndpoint,
              PocketProtocol.isPocketAPAddress(String(describing: host)) else {
            throw PocketError.message("The Wi-Fi connection is outside the Pocket network.")
        }
    }

    private func receiveWiFi(size: Int) async throws {
        guard let connection = socket else { throw PocketError.message("The Wi-Fi socket is closed.") }
        lastByteAt = .now
        let watchdog = Task {
            while !Task.isCancelled {
                if ContinuousClock.now - self.lastByteAt > .seconds(20) { connection.cancel(); break }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        defer { watchdog.cancel() }
        var frame = PocketWiFiFrame(size: size)
        while !frame.hasAllBytes {
            try Task.checkCancellation()
            if let linkError { throw linkError }
            if let transferError { throw transferError }
            let (data, complete) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data ?? Data(), complete)) }
                }
            }
            lastByteAt = .now
            guard let body = frame.consume(data) else { throw PocketError.message("Unexpected data followed the Wi-Fi recording.") }
            if !body.isEmpty { try output?.write(contentsOf: body) }
            received = frame.received
            if complete && !frame.hasAllBytes { throw PocketError.message("The Wi-Fi transfer ended early. Your device recording was kept.") }
            if data.isEmpty && !complete { throw PocketError.message("The Wi-Fi transfer returned no data.") }
        }
        guard frame.markerMatches else { throw PocketError.message("The Wi-Fi end marker did not match.") }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        signalConnectionChange()
        switch central.state {
        case .poweredOn:
            if connectWhenPoweredOn { connectRemembered() }
            else if scanning { beginScan() }
            else if reconnecting { status = "Reconnecting to Pocket" }
            else if connectionTask == nil && !connected { status = "Bluetooth ready" }
        case .poweredOff:
            pauseScan()
            if sessionAccepted {
                reconnecting = true; connected = false; authenticated = false
                clearBattery(); status = "Bluetooth is off. Reconnecting when it is back on"
                operation?.cancel(); socket?.cancel()
                heartbeat?.cancel(); heartbeat = nil
            } else {
                status = "Turn on Bluetooth in iPhone Settings"
                failBluetoothWork("Bluetooth turned off.")
            }
        case .unauthorized:
            pauseScan(); status = "Allow Bluetooth access in iPhone Settings"
            failBluetoothWork("Allow Bluetooth access in iPhone Settings.")
        case .unsupported:
            stopScan(); status = "Bluetooth is not available on this device"
            failBluetoothWork("Bluetooth is not available on this device.")
        default:
            pauseScan()
            status = "Waiting for Bluetooth"
        }
    }

    private func failBluetoothWork(_ message: String) {
        guard connectionTask != nil || connected else { return }
        error = message
        disconnect()
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning, scanStarted else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix("PKT01"), !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        devices.append(PocketPeripheral(peripheral: peripheral, name: name, rssi: RSSI.intValue))
        status = "Pocket found"
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard link.didConnect() else {
            if link.isClosing { central.cancelPeripheralConnection(peripheral) }
            return
        }
        signalConnectionChange()
        connected = true
        setSetupStep("Finding the Pocket service")
        peripheral.discoverServices([CBUUID(string: PocketProtocol.service), CBUUID(string: PocketProtocol.batteryService)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let expected = awaitingPairingDisconnect || link.isClosing
        guard link.didFailToConnect() else { return }
        signalConnectionChange()
        if expected {
            connected = false; linkError = nil
            trace("Connection attempt closed")
            return
        }
        linkError = error ?? PocketError.message("Cannot connect to Pocket.")
        self.error = linkError?.localizedDescription; connected = false
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let expected = awaitingPairingDisconnect || link.isClosing
        guard link.didDisconnect() else { return }
        signalConnectionChange()
        trace("Bluetooth disconnected")
        if expected {
            linkError = nil
        } else {
            linkError = error ?? PocketError.message("Pocket disconnected.")
        }
        operation?.cancel(); heartbeat?.cancel(); heartbeat = nil
        if let wifiSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: wifiSSID) }
        socket?.cancel(); socket = nil
        connected = false; authenticated = false; receivingBLE = false; wifiRaised = false
        live?.cancel(); live = nil; recordingOnDevice = false
        batteryLevelCharacteristic = nil
        clearBattery()
        reconnecting = sessionAccepted
        if central.state == .poweredOff && sessionAccepted { status = "Bluetooth is off. Reconnecting when it is back on" }
        else if sessionAccepted || awaitingPairingDisconnect { status = "Reconnecting to Pocket" }
        else { status = connectionTask == nil ? "Disconnected" : "Pocket disconnected" }
        wifiSSID = nil
        if let error, !expected { self.error = error.localizedDescription }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, link.isConnected else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: PocketProtocol.service) }) else {
            if let error { linkError = error; self.error = error.localizedDescription; return }
            linkError = PocketHandshake.Failure.permanent("Pocket did not expose its control service.")
            return
        }
        setSetupStep("Finding the pairing controls")
        peripheral.discoverCharacteristics([PocketProtocol.command, PocketProtocol.reply, PocketProtocol.audio].map(CBUUID.init(string:)), for: service)
        if let batteryService = peripheral.services?.first(where: { $0.uuid == CBUUID(string: PocketProtocol.batteryService) }) {
            peripheral.discoverCharacteristics([CBUUID(string: PocketProtocol.batteryLevel)], for: batteryService)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, link.isConnected,
              peripheral.services?.contains(where: { $0 === service }) == true else { return }
        if service.uuid == CBUUID(string: PocketProtocol.batteryService) {
            guard error == nil else { return }
            batteryLevelCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: PocketProtocol.batteryLevel) }
            if let batteryLevelCharacteristic {
                if batteryLevelCharacteristic.properties.contains(.notify) || batteryLevelCharacteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: batteryLevelCharacteristic)
                }
                readBatteryLevel()
            }
            return
        }
        guard service.uuid == CBUUID(string: PocketProtocol.service) else { return }
        if let error { linkError = error; self.error = error.localizedDescription; return }
        let characteristics = service.characteristics ?? []
        let writes = Set(characteristics.filter { $0.properties.contains(.write) }.map { $0.uuid.uuidString.uppercased() })
        let withoutResponse = Set(characteristics.filter { $0.properties.contains(.writeWithoutResponse) }.map { $0.uuid.uuidString.uppercased() })
        let selectedUUID = PocketProtocol.commandUUID(writes: writes, writesWithoutResponse: withoutResponse)
        command = characteristics.first { $0.uuid.uuidString.uppercased() == selectedUUID }
        for characteristic in characteristics {
            let uuid = characteristic.uuid.uuidString.uppercased()
            trace("GATT \(uuid): write=\(characteristic.properties.contains(.write)), writeWithoutResponse=\(characteristic.properties.contains(.writeWithoutResponse)), notify=\(characteristic.properties.contains(.notify)), indicate=\(characteristic.properties.contains(.indicate))")
            switch characteristic.uuid.uuidString.uppercased() {
            case PocketProtocol.reply: replies = characteristic
            case PocketProtocol.audio: audio = characteristic
            default: break
            }
        }
        guard command != nil else { linkError = PocketHandshake.Failure.permanent("Pocket has no writable command channel."); return }
        guard let replies, replies.properties.contains(.notify) || replies.properties.contains(.indicate) else {
            linkError = PocketHandshake.Failure.permanent("Pocket has no reply notification channel."); return
        }
        setSetupStep("Enabling pairing replies")
        if replies.isNotifying { notified.insert(PocketProtocol.reply) }
        else { peripheral.setNotifyValue(true, for: replies) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic === batteryLevelCharacteristic { return }
        guard peripheral.identifier == self.peripheral?.identifier, link.isConnected,
              characteristic === replies || characteristic === audio else { return }
        if let error { linkError = error; self.error = error.localizedDescription; return }
        let uuid = characteristic.uuid.uuidString.uppercased()
        trace("Notifications \(uuid): \(characteristic.isNotifying ? "on" : "off")")
        if characteristic.isNotifying { notified.insert(uuid) }
        else { notified.remove(uuid) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, link.isConnected,
              characteristic === command else { return }
        if let error { linkError = error; transferError = error }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic === batteryLevelCharacteristic {
            guard authenticated, error == nil, let value = characteristic.value,
                  let level = PocketProtocol.standardBattery(value) else { return }
            batteryReadings.setStandard(level); trace("Battery standard \(level)%"); updateBattery()
            return
        }
        guard peripheral.identifier == self.peripheral?.identifier,
              characteristic === replies || characteristic === audio else { return }
        if let error { linkError = error; transferError = error; return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == CBUUID(string: PocketProtocol.audio) {
            // While Pocket records, it streams the same MP3 bytes it saves.
            if !receivingBLE, recordingOnDevice { live?.send(value); return }
            guard receivingBLE, output != nil else { return }
            do {
                guard received <= PocketProtocol.maxFileBytes - value.count else { throw PocketError.message("The Bluetooth recording exceeds the file size limit.") }
                try output?.write(contentsOf: value); received += value.count; lastByteAt = .now
                if expected > 0 && received > expected { transferError = PocketError.message("Bluetooth sent more bytes than the recording size. Try Wi-Fi sync.") }
            } catch { transferError = error; receivingBLE = false }
            return
        }
        guard characteristic.uuid == CBUUID(string: PocketProtocol.reply) else { return }
        for message in PocketProtocol.messages(value) {
            if message.type == "SK" { trace("RX SK: \(["OK", "ERR"].contains(message.value) ? message.value : "other result")") }
            else { trace("RX reply") }
            serial += 1; history.append((serial, message)); if history.count > 20_000 { history.removeFirst(10_000) }
            if message.type == "BAT" { trace("RX BAT fields: \(message.value)") }  // Charging field is unknown; keep raw for reports.
            if authenticated, let level = PocketProtocol.vendorBattery(message) {
                batteryReadings.setVendor(level); trace("Battery vendor \(level)%"); updateBattery()
            }
            if message.type == "FW" { firmware = message.value }
            if message.type == "WF" { wifiFirmware = message.value }
            if message.type == "SPA", message.fields.count == 2,
               let free = PocketProtocol.decimal(message.fields[0]), let total = PocketProtocol.decimal(message.fields[1]) {
                storageFreeMB = free; storageTotalMB = total
            }
            if message.type == "STA" { recordingOnDevice = true; startLiveTranscript() }
            if message.type == "STO" {
                recordingOnDevice = false
                live?.finish()
                syncNewRecordings()
            }
        }
    }
}
