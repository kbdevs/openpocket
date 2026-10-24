import Foundation

// Protocol evidence: shahcolate/pocket-libre, commit 5962722710731edbc9a2da22149f0e4fe198366e.
// The independent Android inspection is recorded under research/.
enum PocketProtocol {
    static let service = "001120A0-2233-4455-6677-889912345678"
    static let command = "001120A2-2233-4455-6677-889912345678"
    static let reply = "001120A3-2233-4455-6677-889912345678"
    static let audio = "001120A1-2233-4455-6677-889912345678"
    static let batteryService = "180F"
    static let batteryLevel = "2A19"
    static let wifiHost = "192.168.200.1"
    static let wifiPort: UInt16 = 8475
    static let wifiEnd = Data([0xba, 0x5a, 0x02, 0x8f, 0x04, 0xba, 0x5a, 0x02, 0x8f, 0x04])
    static let maxFileBytes = 1_073_741_824

    static func commandUUID(writes: Set<String>, writesWithoutResponse: Set<String>) -> String? {
        // Both routes are captured. Ignore an A2 that does not advertise write support.
        for uuid in [command, reply] where writes.contains(uuid) || writesWithoutResponse.contains(uuid) { return uuid }
        return nil
    }

    struct Message: Equatable, Sendable {
        var type: String
        var fields: [String]
        var value: String { fields.joined(separator: "&") }
        init?(text: String) {
            let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "&")
            guard fields.count >= 2, fields[0] == "MCU", !fields[1].isEmpty else { return nil }
            type = fields[1]; self.fields = Array(fields.dropFirst(2))
        }
    }

    static func messages(_ data: Data) -> [Message] {
        guard let text = String(data: data, encoding: .ascii) else { return [] }
        return text.replacingOccurrences(of: "\0", with: "").components(separatedBy: "MCU&").dropFirst()
            .compactMap { Message(text: "MCU&" + $0) }
    }

    static func validKey(_ key: String) -> Bool {
        key.utf8.count == 16 && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    static func newSessionKey() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var random = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] })
    }

    static func validDate(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }

    static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    static func isPocketAPAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4,
              parts[0] == "192", parts[1] == "168", parts[2] == "200",
              let host = decimal(String(parts[3])) else { return false }
        return (1...254).contains(host)
    }

    static func decimal(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }

    static func count(_ message: Message, type: String) -> Int? {
        guard message.type == type, message.fields.count == 1 else { return nil }
        return decimal(message.fields[0])
    }

    static func vendorBattery(_ message: Message) -> Int? {
        // The vendor app matches the MCU&BAT& prefix, so later fields (such as charging) are ignored.
        guard message.type == "BAT", let first = message.fields.first,
              let value = decimal(first), (0...100).contains(value) else { return nil }
        return value
    }

    static func standardBattery(_ data: Data) -> Int? {
        guard data.count == 1, let value = data.first, value <= 100 else { return nil }
        return Int(value)
    }

    static func size(_ message: Message) -> Int? {
        guard message.type == "U", message.fields.count == 1,
              let value = decimal(message.fields[0]), value > 0, value <= maxFileBytes else { return nil }
        return value
    }

    static func wifiCredentials(_ message: Message) -> PocketWiFiCredentials? {
        guard message.type == "WIFI", message.fields.count == 2,
              message.fields[0].hasPrefix("PKT01"), message.fields[0].utf8.count <= 32,
              (8...63).contains(message.fields[1].utf8.count) else { return nil }
        return PocketWiFiCredentials(ssid: message.fields[0], password: message.fields[1])
    }

    static func directoryDates(_ entries: [Message], summary: Message) -> [String]? {
        guard let count = count(summary, type: "DIRS_SUM"),
              entries.allSatisfy({ $0.type == "DIRS" && $0.fields.count == 1 && validDate($0.fields[0]) }) else { return nil }
        let dates = Array(Set(entries.map { $0.fields[0] })).sorted(by: >)
        return dates.count == count ? dates : nil
    }

    static func recordings(_ entries: [Message], summary: Message, date: String) -> [DeviceRecording]? {
        guard validDate(date), let count = count(summary, type: "LIST") else { return nil }
        let parsed = entries.compactMap(DeviceRecording.init(message:))
        guard parsed.count == entries.count, parsed.allSatisfy({ $0.date == date }) else { return nil }
        var unique: [String: DeviceRecording] = [:]
        for recording in parsed {
            if let previous = unique[recording.id], previous != recording { return nil }
            unique[recording.id] = recording
        }
        guard unique.count == count else { return nil }
        return Array(unique.values)
    }
}

struct PocketBatteryReadings: Equatable {
    private(set) var vendor: Int?
    private(set) var standard: Int?

    // The vendor app shows only MCU&BAT and never reads 0x2A19, which can report a different value.
    var value: Int? { vendor ?? standard }

    var differ: Bool { vendor != nil && standard != nil && vendor != standard }

    mutating func setVendor(_ value: Int?) {
        guard let value else { vendor = nil; return }
        if (0...100).contains(value) { vendor = value }
    }
    mutating func setStandard(_ value: Int?) {
        guard let value else { standard = nil; return }
        if (0...100).contains(value) { standard = value }
    }
    mutating func reset() { vendor = nil; standard = nil }
}

struct PocketWiFiCredentials: Equatable {
    let ssid: String
    let password: String
}

struct PocketWiFiFrame {
    let size: Int
    private(set) var received = 0
    private var tail = Data()

    init(size: Int) { self.size = size }

    var hasAllBytes: Bool { received == size && tail.count == PocketProtocol.wifiEnd.count }
    var markerMatches: Bool { hasAllBytes && tail == PocketProtocol.wifiEnd }

    mutating func consume(_ data: Data) -> Data? {
        guard size > 0, received <= size else { return nil }
        let bodyCount = min(data.count, size - received)
        let nextTail = data.dropFirst(bodyCount)
        guard tail.count + nextTail.count <= PocketProtocol.wifiEnd.count else { return nil }
        tail.append(contentsOf: nextTail)
        received += bodyCount
        return Data(data.prefix(bodyCount))
    }
}

struct DeviceRecording: Identifiable, Hashable, Sendable {
    var date: String
    var name: String
    var duration: Int
    var id: String { "\(date)/\(name)" }
    init?(message: PocketProtocol.Message) {
        guard message.type == "F", message.fields.count == 3,
              PocketProtocol.validDate(message.fields[0]), PocketProtocol.safeName(message.fields[1]),
              let duration = PocketProtocol.decimal(message.fields[2]), duration <= 31_536_000 else { return nil }
        self.date = message.fields[0]; self.name = message.fields[1]; self.duration = duration
    }
}
