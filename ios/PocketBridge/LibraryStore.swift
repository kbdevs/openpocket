import Foundation
import Observation
import AVFoundation

@MainActor @Observable
final class LibraryStore {
    private(set) var recordings: [Recording] = []
    var error: String?
    private var loadFailed = false
    private var recoveringLegacy = false
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                recordings = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: indexURL))
                guard Set(recordings.map(\.id)).count == recordings.count,
                      recordings.allSatisfy({ $0.audioFile == URL(fileURLWithPath: $0.audioFile).lastPathComponent && !$0.audioFile.contains("/") && !$0.audioFile.contains("\\") && $0.audioFile.hasPrefix($0.id.uuidString + ".") }) else {
                    recordings = []
                    throw PocketError.message("The library index has an invalid audio path or duplicate identifier.")
                }
            }
        } catch {
            loadFailed = true
            self.error = "Cannot open the recording library. The saved index was kept. \(error.localizedDescription)"
        }
    }

    func audioURL(_ recording: Recording) -> URL { directory.appendingPathComponent(recording.audioFile) }
    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    private func persist(_ next: [Recording]) throws {
        guard !loadFailed else { throw PocketError.message("The saved library could not be read. Restore library.json before you save new recordings.") }
        try JSONEncoder().encode(next).write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        recordings = next
    }

    func update(_ id: UUID, _ change: (inout Recording) -> Void) throws {
        var next = recordings
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw PocketError.message("Recording not found.") }
        change(&next[index])
        try persist(next)
    }

    func clearVoiceMatches() throws {
        guard !loadFailed else { throw PocketError.message("Cannot clear voice matches because the saved library could not be read. Restore library.json first.") }
        guard recordings.contains(where: { $0.voiceMatches != nil || $0.voiceProfileChecked != nil }) else { return }
        var next = recordings
        for index in next.indices {
            next[index].voiceMatches = nil
            next[index].voiceProfileChecked = nil
        }
        try persist(next)
    }

    func saveVoiceEnrollment(recordingID: UUID, speaker: String, match: SpeakerVoiceMatch) throws {
        var next = recordings
        guard let selected = next.firstIndex(where: { $0.id == recordingID }) else { throw PocketError.message("Recording not found.") }
        for index in next.indices {
            next[index].voiceMatches = nil
            next[index].voiceProfileChecked = nil
        }
        next[selected].voiceMatches = [speaker: match]
        next[selected].voiceProfileChecked = match.profileID
        try persist(next)
    }

    func pruneVoiceMatches(profileID: UUID) throws {
        guard !loadFailed else { throw PocketError.message("Cannot check voice matches because the saved library could not be read. Restore library.json first.") }
        var next = recordings
        var changed = false
        for index in next.indices {
            if let matches = next[index].voiceMatches {
                let valid = matches.filter { $0.value.profileID == profileID }
                if valid.count != matches.count {
                    next[index].voiceMatches = valid.isEmpty ? nil : valid
                    changed = true
                }
            }
            if let checked = next[index].voiceProfileChecked, checked != profileID {
                next[index].voiceProfileChecked = nil
                changed = true
            }
        }
        if changed { try persist(next) }
    }

    @discardableResult
    func importAudio(_ source: URL, title: String? = nil, origin: String = "Import", recordingID: UUID? = nil) async throws -> UUID {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let id = recordingID ?? UUID()
        if let existing = recording(id) {
            if !FileManager.default.fileExists(atPath: audioURL(existing).path) {
                let destination = audioURL(existing)
                try await Task.detached { try FileManager.default.copyItem(at: source, to: destination) }.value
            }
            return id
        }
        let ext = source.pathExtension.lowercased()
        guard ["wav", "m4a", "mp3", "mp4", "aac", "flac", "aif", "aiff", "caf", "ogg", "opus"].contains(ext) else {
            throw PocketError.message("Select an audio file.")
        }
        let destination = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        if recordingID != nil, FileManager.default.fileExists(atPath: destination.path) {
            // An earlier recovery copied audio but stopped before it wrote the index.
            try FileManager.default.removeItem(at: destination)
        }
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            let asset = AVURLAsset(url: destination)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            var recording = Recording(title: title ?? source.deletingPathExtension().lastPathComponent, audioFile: destination.lastPathComponent)
            recording.id = id
            recording.duration = duration.isFinite ? duration : 0
            recording.source = origin
            recording.language = UserDefaults.standard.string(forKey: "defaultLanguage") ?? "en"
            try persist([recording] + recordings)
            return id
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func delete(_ id: UUID) throws {
        guard let item = recording(id) else { return }
        try persist(recordings.filter { $0.id != id })
        // Keep metadata intact until the index write succeeds.
        try FileManager.default.removeItem(at: audioURL(item))
    }

    /// Adds recordings from a backup folder (a copy of this library's folder). Recordings already here are kept as they are.
    @discardableResult
    func restore(from folder: URL) throws -> Int {
        let saved = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: folder.appendingPathComponent("library.json")))
        var next = recordings
        var added = 0
        for item in saved where recording(item.id) == nil {
            guard item.audioFile == URL(fileURLWithPath: item.audioFile).lastPathComponent, item.audioFile.hasPrefix(item.id.uuidString + ".") else { continue }
            let source = folder.appendingPathComponent(item.audioFile)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if !FileManager.default.fileExists(atPath: audioURL(item).path) { try FileManager.default.copyItem(at: source, to: audioURL(item)) }
            next.append(item)
            added += 1
        }
        if added > 0 { try persist(next) }
        return added
    }
    // Recover files left by older builds; the app no longer records microphone audio.
    @discardableResult
    private func saveLegacyMicrophone(_ url: URL) async throws -> UUID {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Microphone-"), let id = UUID(uuidString: String(name.dropFirst("Microphone-".count))) else {
            throw PocketError.message("Invalid microphone file name. The original file was kept.")
        }
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.now
        let saved = try await importAudio(url, title: "Recording \(date.formatted(date: .abbreviated, time: .shortened))", origin: "Microphone", recordingID: id)
        try FileManager.default.removeItem(at: url)
        return saved
    }

    func recoverLegacyRecordings() async {
        guard !recoveringLegacy, !loadFailed else { return }
        recoveringLegacy = true
        defer { recoveringLegacy = false }
        do {
            let parent = directory.deletingLastPathComponent()
            let files = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            for url in files where url.lastPathComponent.hasPrefix("Microphone-") && url.pathExtension.lowercased() == "m4a" {
                do { _ = try await saveLegacyMicrophone(url) }
                catch { self.error = "A microphone file needs recovery in Files. \(error.localizedDescription)" }
            }
        } catch { self.error = "Cannot check microphone recovery files. \(error.localizedDescription)" }
    }
}
