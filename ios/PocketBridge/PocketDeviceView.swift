import SwiftUI

struct PocketDeviceView: View {
    @Environment(PocketDeviceController.self) private var pocket
    @Environment(LibraryStore.self) private var library
    @State private var selected = Set<String>()
    @State private var wifi = true
    @State private var date = Date()
    private var chosenFiles: [DeviceRecording] { pocket.files.filter { selected.contains($0.id) } }

    var body: some View {
        @Bindable var pocket = pocket
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(pocket.connected || pocket.reconnecting ? pocket.deviceName : pocket.rememberedDevice?.name ?? "Your Pocket").font(.title3.weight(.semibold))
                            Text(pocket.status).font(.subheadline).foregroundStyle(.secondary)
                            if pocket.authenticated {
                                HStack {
                                    if let battery = pocket.battery {
                                        Label("\(battery)%", systemImage: batteryIcon(battery)).monospacedDigit()
                                            .accessibilityLabel("Pocket battery \(battery) percent")
                                    }
                                    if let free = pocket.storageFreeMB { Text("\(ByteCountFormatter.string(fromByteCount: Int64(free) * 1_000_000, countStyle: .file)) free") }
                                    if !pocket.firmware.isEmpty { Text("Firmware \(pocket.firmware)") }
                                }.font(.caption).foregroundStyle(.secondary)
                                if pocket.battery == nil {
                                    Label(pocket.batteryStatus ?? "Battery unavailable", systemImage: "questionmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        if pocket.busy || pocket.scanning || pocket.reconnecting { ProgressView().accessibilityLabel(pocket.status) }
                    }.padding(.vertical, 6)
                    if pocket.busy && pocket.totalFiles > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            if pocket.expected > 0 {
                                ProgressView(value: Double(pocket.received), total: Double(max(1, pocket.expected)))
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(pocket.received), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(pocket.expected), countStyle: .file))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text("\(pocket.completedFiles) of \(pocket.totalFiles) recordings saved").font(.caption)
                        }
                    }
                    if let error = pocket.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if pocket.error != nil && !pocket.connectionLog.isEmpty {
                        ShareLink(item: pocket.connectionReport) { Label("Share connection report", systemImage: "square.and.arrow.up") }
                    }
                    if pocket.reconnecting { Button("Stop reconnecting", role: .cancel) { pocket.userDisconnect() } }
                    else if pocket.busy { Button("Stop", role: .cancel) { pocket.cancel() } }
                    else if pocket.connected { Button("Disconnect") { pocket.userDisconnect() } }
                    else {
                        if let saved = pocket.rememberedDevice, !pocket.scanning {
                            Button("Connect to \(saved.name)", systemImage: "link") { pocket.connectRemembered(userInitiated: true) }
                        }
                        Button(pocket.scanning ? "Stop scan" : "Find Pocket", systemImage: pocket.scanning ? "stop.circle" : "antenna.radiowaves.left.and.right") {
                            if pocket.scanning { pocket.stopScan() } else { pocket.scan() }
                        }
                    }
                }
                if !pocket.authenticated && !pocket.reconnecting {
                    Section {
                        ForEach(pocket.devices) { device in
                            Button { pocket.pair(device) } label: {
                                HStack { Text(device.name).foregroundStyle(.primary); Spacer(); Text("Pair").fontWeight(.semibold) }
                            }.disabled(pocket.busy)
                        }
                    }
                } else if pocket.authenticated {
                    Section {
                        Picker("Transfer", selection: $wifi) { Text("Wi-Fi · Fast").tag(true); Text("Bluetooth").tag(false) }.pickerStyle(.segmented).disabled(pocket.busy)
                        Toggle("Auto sync new recordings", isOn: $pocket.autoSync).disabled(pocket.busy)
                        Button("Load recordings", systemImage: "arrow.down.circle") { selected = []; pocket.refresh() }.disabled(pocket.busy)
                        DatePicker("Only this date", selection: $date, displayedComponents: .date)
                        Button("Load this date") { selected = []; pocket.refresh(date: date) }.disabled(pocket.busy)
                    }
                    Section {
                        if pocket.recordingOnDevice {
                            LiveTranscriptView(live: pocket.live)
                            Button("Stop recording", role: .destructive) { pocket.stopRecording() }.disabled(pocket.busy)
                        } else {
                            Button("Start recording", systemImage: "record.circle") { pocket.startRecording() }.disabled(pocket.busy)
                        }
                    } footer: { Text("Experimental. Pocket may ignore these commands.") }
                    if !pocket.files.isEmpty {
                        Section {
                            Button(selected.count == pocket.files.count ? "Clear selection" : "Select new recordings") {
                                selected = selected.count == pocket.files.count ? [] : Set(pocket.files.filter { !pocket.imported($0) }.map(\.id))
                            }.disabled(pocket.busy)
                            ForEach(pocket.files) { file in
                                Button {
                                    if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(file.id) ? .indigo : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(recordedAt(file)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                            Text(timeLabel(Double(file.duration))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if pocket.imported(file) { Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityLabel("Saved on iPhone") }
                                    }.padding(.vertical, 5).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(pocket.busy)
                            }
                        }
                    }
                }
                if pocket.rememberedDevice != nil && !pocket.busy {
                    Section { Button("Forget this Pocket", role: .destructive) { pocket.forgetRememberedDevice() } }
                }
            }
            .navigationTitle("Pocket")
            .safeAreaInset(edge: .bottom) {
                if !chosenFiles.isEmpty && pocket.authenticated && !pocket.busy {
                    Button { pocket.sync(chosenFiles, wifi: wifi) } label: {
                        Label("Sync \(chosenFiles.count) \(chosenFiles.count == 1 ? "recording" : "recordings")", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).padding(16).background(.bar)
                }
            }
        }
    }

    /// Pocket names files by UTC start time (yyyyMMddHHmmss). Show it in local time.
    private func recordedAt(_ file: DeviceRecording) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"; formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: String(file.name.prefix(14))) else { return file.name }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 0...10: "battery.0percent"
        case 11...37: "battery.25percent"
        case 38...62: "battery.50percent"
        case 63...87: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

