import Foundation
import Security
import AVFoundation

enum Keychain {
    private static let service = "app.pocketbridge.backend"
    static func token() -> String { value(for: "token") }
    static func value(for account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func setToken(_ token: String) throws { try set(token, for: "token") }
    static func set(_ token: String, for account: String, accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PocketError.message("Cannot remove the backend token.") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                        kSecAttrAccessible as String: accessibility]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw PocketError.message("Cannot save the backend token.") }
    }
}

struct RemoteRecording: Decodable, Sendable {
    var id: String
    var status: String
    var title: String?
    var duration: Double?
    var language: String?
    var segments: [TranscriptSegment]?
    var summary: String?
    var actions: [ActionItem]?
    var error: String?
}

struct NotesResponse: Decodable { var title: String; var summary: String; var actions: [ActionItem] }
private struct ChatResponse: Decodable { var answer: String }

struct BackendClient: Sendable {
    let baseURL: URL
    let token: String

    @MainActor static func configured() throws -> BackendClient {
        let address = UserDefaults.standard.string(forKey: "backendURL") ?? ""
        guard let url = URL(string: address), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw PocketError.message("Use an HTTPS service URL. HTTP is allowed for localhost development.")
        }
        let token = Keychain.token()
        guard !token.isEmpty else { throw PocketError.message("Add your service URL and access token in Settings.") }
        return BackendClient(baseURL: url, token: token)
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let response = response as? HTTPURLResponse else { throw PocketError.message("The service did not return an HTTP response.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw PocketError.message(detail ?? "Service request failed (HTTP \(response.statusCode)).")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func upload(_ file: URL, recordingID: UUID, title: String, language: String) async throws -> RemoteRecording {
        let prepared = try await Self.prepareAudio(file)
        defer { if prepared != file { try? FileManager.default.removeItem(at: prepared) } }
        let boundary = "PocketBridge-\(UUID().uuidString)"
        let body = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let output = try FileHandle(forWritingTo: body)
        let input = try FileHandle(forReadingFrom: prepared)
        do {
            let serviceTitle = String(title.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(200))
            for (name, value) in [("title", serviceTitle), ("language", language)] {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            let ext = prepared.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close(); try input.close()
        } catch { try? output.close(); try? input.close(); throw error }
        var req = request("v1/recordings", method: "POST")
        req.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: body)
        return try decode(RemoteRecording.self, data: data, response: response)
    }

    static func prepareAudio(_ source: URL) async throws -> URL {
        guard ["aif", "aiff", "caf"].contains(source.pathExtension.lowercased()) else { return source }
        let destination = URL.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).m4a")
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw PocketError.message("Cannot prepare this audio format for transcription.")
        }
        exporter.outputURL = destination; exporter.outputFileType = .m4a
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in exporter.exportAsynchronously { continuation.resume() } }
        } onCancel: { exporter.cancelExport() }
        do {
            try Task.checkCancellation()
            guard exporter.status == .completed else { throw exporter.error ?? PocketError.message("Audio conversion failed. The original file was kept.") }
            return destination
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    func recording(_ id: String) async throws -> RemoteRecording {
        guard UUID(uuidString: id) != nil else { throw PocketError.message("Invalid job identifier.") }
        let (data, response) = try await URLSession.shared.data(for: request("v1/recordings/\(id)"))
        return try decode(RemoteRecording.self, data: data, response: response)
    }

    func retry(_ id: String) async throws {
        guard UUID(uuidString: id) != nil else { throw PocketError.message("Invalid job identifier.") }
        let (data, response) = try await URLSession.shared.data(for: request("v1/recordings/\(id)/retry", method: "POST"))
        _ = try decode(RemoteRecording.self, data: data, response: response)
    }

    func delete(_ id: String) async throws {
        guard UUID(uuidString: id) != nil else { throw PocketError.message("Invalid job identifier.") }
        let (_, response) = try await URLSession.shared.data(for: request("v1/recordings/\(id)", method: "DELETE"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PocketError.message("Cannot remove the recording from the service.") }
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        var req = request(path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(type, data: data, response: response)
    }

    private func segmentObjects(_ segments: [TranscriptSegment]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(segments))
    }
    func summarize(_ segments: [TranscriptSegment], template: String) async throws -> NotesResponse {
        try await post("v1/summarize", body: ["segments": try segmentObjects(segments), "template": template], as: NotesResponse.self)
    }
    func chat(_ segments: [TranscriptSegment], question: String) async throws -> String {
        try await post("v1/chat", body: ["segments": try segmentObjects(segments), "question": question], as: ChatResponse.self).answer
    }
}
