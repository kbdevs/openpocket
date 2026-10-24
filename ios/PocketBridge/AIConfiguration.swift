import Foundation

enum AIConfiguration {
    static let deepgramAccount = "deepgram-api-key"
    static let openRouterAccount = "openrouter-api-key"

    // New recordings always use the build's AI keys. Older server jobs still resume through BackendClient.
    static let usesService = false
    static var canMakeNotes: Bool { usesService || directClient().canMakeNotes }

    // Keys/PocketBridgeAI.plist is copied into the app. Git ignores it.
    private static var bundled: [String: String] {
        guard let url = Bundle.main.url(forResource: "PocketBridgeAI", withExtension: "plist", subdirectory: "Keys"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    static func key(_ account: String, bundledName: String) -> String {
        (bundled[bundledName] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func directClient() -> DirectAIClient {
        DirectAIClient(
            deepgramKey: key(deepgramAccount, bundledName: "DEEPGRAM_API_KEY"),
            openRouterKey: key(openRouterAccount, bundledName: "OPENROUTER_API_KEY"),
            model: bundled["OPENROUTER_MODEL"] ?? "google/gemini-2.5-flash"
        )
    }

    @MainActor static func summarize(_ segments: [TranscriptSegment], template: String) async throws -> NotesResponse {
        if usesService { return try await BackendClient.configured().summarize(segments, template: template) }
        return try await directClient().summarize(segments, template: template)
    }

    @MainActor static func chat(_ segments: [TranscriptSegment], question: String) async throws -> String {
        if usesService { return try await BackendClient.configured().chat(segments, question: question) }
        return try await directClient().chat(segments, question: question)
    }
}
