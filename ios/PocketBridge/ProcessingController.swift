import Foundation
import Observation

@MainActor @Observable
final class ProcessingController {
    private(set) var active: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let library: LibraryStore
    private let voice: VoiceProfileStore?
    private let directClient: DirectAIClient?
    init(library: LibraryStore, voice: VoiceProfileStore? = nil, directClient: DirectAIClient? = nil) {
        self.library = library; self.voice = voice; self.directClient = directClient
    }

    func process(_ id: UUID) {
        guard !active.contains(id), let item = library.recording(id) else { return }
        active.insert(id)
        tasks[id] = Task {
            defer { active.remove(id); tasks[id] = nil }
            do {
                if item.backendID == nil && !AIConfiguration.usesService {
                    try await processDirect(item)
                    return
                }
                let client = try BackendClient.configured()
                if item.backendID != nil, let address = item.backendURL, address != client.baseURL.absoluteString {
                    throw PocketError.message("This job belongs to \(address). Use that service in Settings to resume it.")
                }
                var remoteID = item.backendID
                if let existing = remoteID, item.status == "failed" {
                    try await client.retry(existing)
                    try library.update(id) { $0.status = "queued"; $0.error = nil }
                }
                if remoteID == nil {
                    try library.update(id) { $0.status = "uploading"; $0.error = nil }
                    let remote = try await client.upload(library.audioURL(item), recordingID: item.id, title: item.title, language: item.language)
                    remoteID = remote.id
                    try library.update(id) { $0.backendID = remote.id; $0.backendURL = client.baseURL.absoluteString; $0.status = remote.status }
                }
                guard let remoteID else { throw PocketError.message("The service did not return a job identifier.") }
                while !Task.isCancelled {
                    let remote = try await client.recording(remoteID)
                    let shouldMatchVoice = library.recording(id)?.segments.isEmpty == true && remote.segments?.isEmpty == false
                    let wasComplete = library.recording(id)?.status == "complete"
                    try library.update(id) { local in
                        local.applyRemote(remote)
                    }
                    if shouldMatchVoice { await voice?.match(id) }
                    if remote.status == "complete", !wasComplete, let done = library.recording(id) { Notifier.recordingReady(done) }
                    if ["complete", "failed"].contains(remote.status) { break }
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError {
                // Saved speech and server job identifiers can be resumed.
            } catch {
                try? library.update(id) { $0.error = error.localizedDescription; if $0.backendID == nil { $0.status = "failed" } }
            }
        }
    }

    private func processDirect(_ item: Recording) async throws {
        let client = directClient ?? AIConfiguration.directClient()
        if !item.hasSpeechCheckpoint {
            try library.update(item.id) { $0.status = "transcribing"; $0.error = nil }
            let speech = try await client.transcribe(library.audioURL(item), language: item.language)
            try Task.checkCancellation()
            // Save speech before a second paid provider call, even when no speech was found.
            try library.update(item.id) { local in
                if !local.hasSpeechCheckpoint { local.segments = speech.segments }
                local.speechComplete = true
                local.duration = speech.duration > 0 ? speech.duration : local.duration
                local.language = speech.language
                local.status = "summarizing"
            }
        }
        try Task.checkCancellation()
        guard library.recording(item.id) != nil else { return }
        await voice?.match(item.id)
        try Task.checkCancellation()
        guard let current = library.recording(item.id) else { return }
        try library.update(item.id) { $0.status = "summarizing"; $0.error = nil }
        if current.segments.isEmpty {
            try library.update(item.id) { $0.status = "complete"; $0.error = "No speech was found in this recording." }
            return
        }
        guard client.canMakeNotes else {
            try library.update(item.id) { $0.status = "complete"; $0.error = nil }
            if let done = library.recording(item.id) { Notifier.recordingReady(done) }
            return
        }
        let transcript = current.namedSegments
        let notes = try await client.summarize(transcript, template: "meeting")
        try Task.checkCancellation()
        try library.update(item.id) { local in
            local.status = "complete"
            if local.namedSegments == transcript {
                if local.titleIsLocal != true { local.title = notes.title }
                if local.summaryIsLocal != true { local.summary = notes.summary }
                if local.actionsAreLocal != true { local.actions = notes.actions }
            } else {
                local.error = "The transcript changed. Tap Make notes to use your edits."
            }
        }
        if let done = library.recording(item.id) { Notifier.recordingReady(done) }
    }

    func resumePending() {
        for item in library.recordings where ["queued", "processing", "uploading", "transcribing", "summarizing"].contains(item.status) { process(item.id) }
    }
    func cancel(_ id: UUID) { tasks[id]?.cancel() }
}

extension Recording {
    mutating func applyRemote(_ remote: RemoteRecording) {
        status = remote.status; error = remote.error
        if segments.isEmpty, let transcript = remote.segments, !transcript.isEmpty { segments = transcript }
        // The service replaces the upload title with the AI title when notes complete.
        if titleIsLocal != true, remote.status == "complete", let name = remote.title, !name.isEmpty { title = name }
        if summaryIsLocal != true, let notes = remote.summary { summary = notes }
        if actionsAreLocal != true, let items = remote.actions { actions = items }
        if let length = remote.duration, length.isFinite && length > 0 { duration = length }
        if let locale = remote.language { language = locale }
    }
}
