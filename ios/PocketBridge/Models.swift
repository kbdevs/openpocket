import Foundation

struct TranscriptSegment: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

struct SpeakerVoiceMatch: Codable, Sendable, Equatable {
    var profileID: UUID
    var similarity: Double
    var confirmed: Bool
    var rejected: Bool

    init(profileID: UUID, similarity: Double, confirmed: Bool = false, rejected: Bool = false) {
        self.profileID = profileID
        self.similarity = similarity
        self.confirmed = confirmed
        self.rejected = rejected
    }
}

struct ActionItem: Codable, Identifiable, Sendable {
    var id: String
    var text: String
    var owner: String?
    var done: Bool = false

    enum CodingKeys: String, CodingKey { case id, text, owner, done }
    init(id: String, text: String, owner: String? = nil, done: Bool = false) {
        self.id = id; self.text = text; self.owner = owner; self.done = done
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        owner = try values.decodeIfPresent(String.self, forKey: .owner)
        done = try values.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

struct Recording: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var audioFile: String
    var duration: Double = 0
    var source: String = "Import"
    var backendID: String?
    var deviceFileID: String?
    var backendURL: String?
    var status: String = "local"
    var language: String = "en"
    var segments: [TranscriptSegment] = []
    var summary: String = ""
    var actions: [ActionItem] = []
    var summaryIsLocal: Bool?
    var titleIsLocal: Bool?
    var actionsAreLocal: Bool?
    var speechComplete: Bool?
    var speakerNames: [String: String] = [:]
    var voiceMatches: [String: SpeakerVoiceMatch]?
    var voiceProfileChecked: UUID?
    var bookmarks: [Double] = []
    var folder: String = ""
    var error: String?

    var hasSpeechCheckpoint: Bool { speechComplete == true || !segments.isEmpty }

    var searchableText: String {
        ([title, summary, folder] + segments.map(\.text)).joined(separator: " ")
    }
    func speakerName(_ speaker: String) -> String {
        if let name = speakerNames[speaker] { return name }
        if voiceMatches?[speaker]?.confirmed == true, voiceMatches?[speaker]?.rejected != true { return "You" }
        return speaker
    }
    var namedSegments: [TranscriptSegment] {
        segments.map { segment in var segment = segment; segment.speaker = speakerName(segment.speaker); return segment }
    }
    var transcriptText: String {
        segments.map { "[\(timeLabel($0.start))] \(speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
    }
    var exportText: String {
        "# \(title)\n\n\(summary)\n\n" + actions.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n\n## Transcript\n\n" + transcriptText
    }
}

func timeLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, min(seconds, Double(Int32.max)))) : 0
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}

enum PocketError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
