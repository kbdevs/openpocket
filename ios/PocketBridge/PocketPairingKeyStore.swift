import Foundation
import Security

// The Pocket the app reconnects to on launch. Its key stays in Keychain.
struct PocketRememberedDevice: Codable, Equatable {
    static let defaultsKey = "pocket.rememberedDevice"
    let id: UUID
    let name: String

    static func load(from defaults: UserDefaults = .standard) -> PocketRememberedDevice? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    static func forget(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

struct PocketPairingKeyStore {
    private let service: String

    init(service: String = "app.pocketbridge.pairing") {
        self.service = service
    }

    func key(for deviceID: UUID) throws -> String {
        let account = deviceID.uuidString
        if let key = try read(account: account) { return key }

        let key = PocketProtocol.newSessionKey()
        let status = SecItemAdd(item(key, account: account) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let savedKey = try read(account: account) else {
                throw PocketError.message("Cannot save the Pocket pairing key in Keychain.")
            }
            return savedKey
        }
        guard status == errSecSuccess else {
            throw PocketError.message("Cannot save the Pocket pairing key in Keychain.")
        }
        return key
    }

    /// The device with the most recently saved key. Builds before 75 saved keys but not the device.
    func lastPairedDeviceID() -> UUID? {
        var query = self.query(account: "")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return nil }
        return items
            .sorted { ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast) > ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast) }
            .lazy.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }.first
    }

    // Reads without creating, so a missing key never becomes a new pairing.
    func savedKey(for deviceID: UUID) throws -> String? {
        try read(account: deviceID.uuidString)
    }

    func remember(_ key: String, for deviceID: UUID) throws {
        guard PocketProtocol.validKey(key) else {
            throw PocketError.message("The Pocket pairing key is invalid.")
        }
        let account = deviceID.uuidString
        var status = SecItemUpdate(query(account: account) as CFDictionary, values(key) as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item(key, account: account) as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PocketError.message("Cannot save the Pocket pairing key in Keychain.")
        }
    }

    private func read(account: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(account: account, returningData: true) as CFDictionary, &result)
        return try Self.storedKey(status: status, data: result as? Data)
    }

    private func query(account: String, returningData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private func item(_ key: String, account: String) -> [String: Any] {
        query(account: account).merging(values(key)) { _, new in new }
    }

    private func values(_ key: String) -> [String: Any] {
        [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    static func storedKey(status: OSStatus, data: Data?) throws -> String? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PocketError.message("Cannot read the saved Pocket pairing key from Keychain.")
        }
        guard let data, let key = String(data: data, encoding: .utf8), PocketProtocol.validKey(key) else {
            throw PocketError.message("The saved Pocket pairing key is invalid.")
        }
        return key
    }

    static func startPairing(
        for deviceID: UUID,
        keyFor: (UUID) throws -> String,
        startConnection: (String) -> Void
    ) throws {
        let key = try keyFor(deviceID)
        startConnection(key)
    }
}
