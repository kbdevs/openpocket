import AVFoundation
import Foundation
import Observation
import Security

struct VoiceProfileCredential: Codable, Equatable, Sendable {
    var id: UUID
    var modelID: String
    var vector: [Float]
    /// Recordings blended into the vector. Nil for profiles saved before learning existed.
    var samples: Int?
}

struct VoiceAudioWindow: Equatable, Sendable {
    let start: Double
    var end: Double { start + 3 }
}

enum VoiceWindowSelector {
    static func select(_ segments: [TranscriptSegment], speaker: String, duration: Double) throws -> [VoiceAudioWindow] {
        guard duration.isFinite, duration > 0 else { throw PocketError.message("The recording duration is invalid.") }
        guard !speaker.isEmpty else { return [] }
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                  segment.end > segment.start, segment.end <= duration else {
                throw PocketError.message("The transcript has timestamps outside this recording. Voice matching was skipped.")
            }
        }

        let others = segments.filter { $0.speaker != speaker }
        let sorted = segments.filter { $0.speaker == speaker }.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        // Transcripts split speech into short phrases. Join phrases with a short pause and nobody else talking between them.
        var selected: [(start: Double, end: Double)] = []
        for segment in sorted {
            if let last = selected.last, segment.start - last.end <= 1.0,
               !others.contains(where: { $0.start < segment.start && last.end < $0.end }) {
                selected[selected.count - 1].end = max(last.end, segment.end)
            } else {
                selected.append((segment.start, segment.end))
            }
        }
        var windows: [VoiceAudioWindow] = []
        for segment in selected {
            let safeStart = segment.start + 0.1
            let safeEnd = segment.end - 0.1
            var start = safeStart
            while start + 3 <= safeEnd + 0.000_001 {
                let end = start + 3
                let overlapsAnotherSpeaker = others.contains { $0.start < end && start < $0.end }
                let overlapsSelectedWindow = windows.contains { $0.start < end && start < $0.end }
                if !overlapsAnotherSpeaker && !overlapsSelectedWindow {
                    windows.append(VoiceAudioWindow(start: start))
                    if windows.count == 9 { return windows }
                }
                start += 3
            }
        }
        return windows
    }
}

struct VoiceMatchCandidate: Equatable, Sendable {
    let speaker: String
    let similarity: Double
}

enum VoiceMatchPolicy {
    static let dimension = 192
    /// Pocket's 32 kbps MP3 scores lower than studio audio, so suggestions start at 0.55.
    static let threshold = 0.55
    /// A unique match at or above this is tagged as you without review.
    static let autoConfirmThreshold = 0.65
    static let version = 3
    static let ambiguityMargin = 0.05
    static let minimumWindows = 3

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0.000_001 else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }

    static func normalizedAverage(_ vectors: [[Float]]) -> [Float]? {
        guard !vectors.isEmpty else { return nil }
        var vectorsNormalized: [[Float]] = []
        vectorsNormalized.reserveCapacity(vectors.count)
        for vector in vectors {
            guard let vectorNormalized = normalized(vector) else { return nil }
            vectorsNormalized.append(vectorNormalized)
        }
        var total = [Double](repeating: 0, count: dimension)
        for vector in vectorsNormalized {
            for index in vector.indices { total[index] += Double(vector[index]) }
        }
        return normalized(total.map { Float($0 / Double(vectorsNormalized.count)) })
    }

    static func cosine(_ first: [Float], _ second: [Float]) -> Double? {
        guard let lhs = normalized(first), let rhs = normalized(second) else { return nil }
        let score = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        guard score.isFinite else { return nil }
        return min(1, max(-1, score))
    }

    static func cosineScores(_ vectors: [[Float]], against reference: [Float]) -> [Double]? {
        var scores: [Double] = []
        scores.reserveCapacity(vectors.count)
        for vector in vectors {
            guard let score = cosine(vector, reference) else { return nil }
            scores.append(score)
        }
        return scores
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
        return sorted[middle]
    }

    static func suggestionScore(_ scores: [Double]) -> Double? {
        guard scores.count >= minimumWindows, scores.allSatisfy(\.isFinite),
              scores.filter({ $0 >= threshold }).count >= 2,
              let median = median(scores), median >= threshold else { return nil }
        return median
    }

    static func uniqueSuggestion(_ candidates: [VoiceMatchCandidate]) -> VoiceMatchCandidate? {
        let ranked = candidates.sorted {
            $0.similarity == $1.similarity ? $0.speaker < $1.speaker : $0.similarity > $1.similarity
        }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, best.similarity - ranked[1].similarity <= ambiguityMargin { return nil }
        return best
    }

    static func canApply(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        profileID: UUID,
        currentProfileID: UUID?,
        enabled: Bool,
        recordingExists: Bool,
        segmentsUnchanged: Bool,
        audioUnchanged: Bool
    ) -> Bool {
        capturedGeneration == currentGeneration && profileID == currentProfileID && enabled &&
            recordingExists && segmentsUnchanged && audioUnchanged
    }
}

@MainActor @Observable
final class VoiceProfileStore {
    private(set) var hasProfile = false
    private(set) var working = false
    private(set) var status: String?
    private(set) var error: String?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let embedding = SpeakerEmbedding()
    @ObservationIgnored private let keychainAccount: String
    @ObservationIgnored private let enabledDefaultsKey: String
    @ObservationIgnored private var profile: VoiceProfileCredential?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var matchTasks: [UUID: ActiveMatch] = [:]
    private var enabledValue = false

    private struct ActiveMatch {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    static let profileAccount = "voice-profile-v1"

    var enabled: Bool {
        get { hasProfile && enabledValue }
        set { setEnabled(newValue) }
    }

    init(library: LibraryStore) {
        self.library = library
        keychainAccount = Self.profileAccount
        enabledDefaultsKey = "voiceRecognitionEnabled"
        let saved = Keychain.value(for: keychainAccount)
        let loaded = Self.decodeProfile(saved)
        profile = loaded
        hasProfile = loaded != nil
        enabledValue = hasProfile && UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        if !hasProfile { UserDefaults.standard.set(false, forKey: enabledDefaultsKey) }
        if !saved.isEmpty && !hasProfile { error = "The saved voice profile is invalid or uses a different model. Enroll again to replace it." }
        if let loaded {
            do { try library.pruneVoiceMatches(profileID: loaded.id) }
            catch { self.error = error.localizedDescription }
        }
    }

    init(library: LibraryStore, keychainAccount: String) {
        self.library = library
        self.keychainAccount = keychainAccount
        enabledDefaultsKey = "voiceRecognitionEnabled.\(keychainAccount)"
        let saved = Keychain.value(for: keychainAccount)
        let loaded = Self.decodeProfile(saved)
        profile = loaded
        hasProfile = loaded != nil
        enabledValue = hasProfile && UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        if !hasProfile { UserDefaults.standard.set(false, forKey: enabledDefaultsKey) }
        if !saved.isEmpty && !hasProfile { error = "The saved voice profile is invalid or uses a different model. Enroll again to replace it." }
        if let loaded {
            do { try library.pruneVoiceMatches(profileID: loaded.id) }
            catch { self.error = error.localizedDescription }
        }
    }

    func enroll(recordingID: UUID, speaker: String) {
        startOwnedTask { [weak self] generation in
            guard let self else { return }
            do {
                try await self.performEnrollment(recordingID: recordingID, speaker: speaker, generation: generation)
                guard self.generation == generation else { return }
                self.enabledValue = true
                UserDefaults.standard.set(true, forKey: self.enabledDefaultsKey)
                await self.scanSavedRecordings(generation: generation, force: false)
            } catch is CancellationError {
                return
            } catch {
                if self.generation == generation { self.error = error.localizedDescription }
            }
        }
    }

    func scanLibrary() {
        guard hasProfile else { status = "Choose a Pocket recording to enroll first."; return }
        guard enabled else { status = "Turn on My voice before scanning recordings."; return }
        startOwnedTask { [weak self] generation in
            await self?.scanSavedRecordings(generation: generation, force: true)
        }
    }

    private func scanSavedRecordings(generation: UInt64, force: Bool) async {
        guard let profile, self.generation == generation, enabled else { return }
        let recordings = library.recordings.filter {
            !$0.segments.isEmpty && (force || $0.voiceProfileChecked != profile.id) &&
                FileManager.default.fileExists(atPath: library.audioURL($0).path)
        }
        for (index, recording) in recordings.enumerated() {
            guard self.generation == generation, enabled else { return }
            status = "Scanning recording \(index + 1) of \(recordings.count)"
            do {
                try await performMatch(recordingID: recording.id, profile: profile, generation: generation, force: force)
            } catch is CancellationError {
                return
            } catch {
                if self.generation == generation { self.error = error.localizedDescription }
            }
        }
        if self.generation == generation { status = "Voice profile saved. Checked \(recordings.count) recordings." }
    }

    func cancel() {
        invalidateWork()
    }

    func deleteProfile() throws {
        let wasEnabled = enabledValue
        invalidateWork()
        enabledValue = false
        UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
        do {
            try library.clearVoiceMatches()
        } catch {
            restoreEnabled(wasEnabled)
            self.error = error.localizedDescription
            throw error
        }
        do {
            try Keychain.set("", for: keychainAccount, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        } catch {
            restoreEnabled(wasEnabled)
            let failure = PocketError.message("Cannot remove the voice profile from this device.")
            self.error = failure.localizedDescription
            throw failure
        }
        profile = nil
        hasProfile = false
        enabledValue = false
        error = nil
        status = nil
    }

    func confirmMatch(recordingID: UUID, speaker: String) throws {
        guard let profile else { throw PocketError.message("Enroll a voice profile before confirming a match.") }
        guard let recording = library.recording(recordingID), recording.segments.contains(where: { $0.speaker == speaker }),
              var match = recording.voiceMatches?[speaker], match.profileID == profile.id,
              match.similarity.isFinite, match.similarity >= VoiceMatchPolicy.threshold else {
            throw PocketError.message("This possible voice match is no longer available.")
        }
        if recording.voiceMatches?.contains(where: { $0.key != speaker && $0.value.profileID == profile.id && $0.value.confirmed && !$0.value.rejected }) == true {
            throw PocketError.message("This recording already has a confirmed speaker.")
        }
        match.confirmed = true
        match.rejected = false
        try library.update(recordingID) { $0.voiceMatches?[speaker] = match }
    }

    func rejectMatch(recordingID: UUID, speaker: String) throws {
        guard let profile else { throw PocketError.message("Enroll a voice profile before rejecting a match.") }
        guard let recording = library.recording(recordingID), recording.segments.contains(where: { $0.speaker == speaker }),
              var match = recording.voiceMatches?[speaker], match.profileID == profile.id,
              match.similarity.isFinite else {
            throw PocketError.message("This possible voice match is no longer available.")
        }
        match.confirmed = false
        match.rejected = true
        try library.update(recordingID) { $0.voiceMatches?[speaker] = match }
    }

    func match(_ id: UUID, force: Bool = false) async {
        guard enabled, let profile, matchTasks[id] == nil else { return }
        let ticket = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performMatch(recordingID: id, profile: profile, generation: ticket, force: force)
                if self.generation == ticket { self.error = nil }
            } catch is CancellationError {
                return
            } catch {
                if self.generation == ticket { self.error = error.localizedDescription }
            }
        }
        matchTasks[id] = ActiveMatch(generation: ticket, task: task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if matchTasks[id]?.generation == ticket { matchTasks[id] = nil }
    }

    private func startOwnedTask(_ work: @escaping @MainActor (UInt64) async -> Void) {
        invalidateWork()
        let ticket = generation
        working = true
        error = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            await work(ticket)
            if self.generation == ticket {
                self.working = false
                self.operationTask = nil
            }
        }
    }

    private func setEnabled(_ requested: Bool) {
        if !requested {
            if enabledValue || working || !matchTasks.isEmpty { invalidateWork() }
            enabledValue = false
            UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
            return
        }
        guard hasProfile else {
            enabledValue = false
            UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
            return
        }
        guard !enabledValue else { return }
        invalidateWork()
        enabledValue = true
        UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
    }

    private func restoreEnabled(_ value: Bool) {
        enabledValue = hasProfile && value
        UserDefaults.standard.set(enabledValue, forKey: enabledDefaultsKey)
    }

    private func invalidateWork() {
        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        for active in matchTasks.values { active.task.cancel() }
        matchTasks.removeAll()
        working = false
        status = nil
    }

    private func performEnrollment(recordingID: UUID, speaker: String, generation ticket: UInt64) async throws {
        guard let recording = library.recording(recordingID) else { throw PocketError.message("Recording not found.") }
        guard recording.source.hasPrefix("Pocket · ") else {
            throw PocketError.message("Choose a timestamped recording saved from Pocket.")
        }
        guard recording.createdAt.timeIntervalSince1970.isFinite,
              recording.segments.contains(where: { $0.speaker == speaker }) else {
            throw PocketError.message("Choose a diarized speaker from this Pocket recording.")
        }
        let audioURL = library.audioURL(recording)
        let audioFile = recording.audioFile
        let segments = recording.segments
        let fingerprint = try audioFingerprint(audioURL)
        let duration = try await audioDuration(audioURL)
        let windows = try VoiceWindowSelector.select(segments, speaker: speaker, duration: duration)
        guard windows.count >= VoiceMatchPolicy.minimumWindows else {
            throw chooseAnotherRecordingError
        }
        let vectors = try await embeddings(windows, audioURL: audioURL, generation: ticket) { index, count in
            self.status = "Reading voice window \(index) of \(count)"
        }
        guard vectors.count >= VoiceMatchPolicy.minimumWindows,
              let vector = VoiceMatchPolicy.normalizedAverage(vectors) else {
            throw chooseAnotherRecordingError
        }
        try Task.checkCancellation()
        guard ticket == generation,
              enrollmentInputIsStable(recordingID: recordingID, audioFile: audioFile, fingerprint: fingerprint, segments: segments) else {
            throw CancellationError()
        }

        let id = UUID()
        let newProfile = VoiceProfileCredential(id: id, modelID: SpeakerEmbedding.modelID, vector: vector)
        guard let scores = VoiceMatchPolicy.cosineScores(vectors, against: vector),
              let similarity = VoiceMatchPolicy.median(scores) else {
            throw SpeakerEmbeddingError.invalidEmbedding
        }
        let previous = Keychain.value(for: keychainAccount)
        do {
            try Keychain.set(try Self.encode(newProfile), for: keychainAccount, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        } catch {
            throw PocketError.message("Cannot save the voice profile to this device.")
        }
        do {
            try library.saveVoiceEnrollment(recordingID: recordingID, speaker: speaker,
                match: SpeakerVoiceMatch(profileID: id, similarity: similarity, confirmed: true))
        } catch {
            try? Keychain.set(previous, for: keychainAccount, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
            throw error
        }
        profile = newProfile
        hasProfile = true
    }

    private func performMatch(recordingID: UUID, profile candidateProfile: VoiceProfileCredential, generation ticket: UInt64, force: Bool) async throws {
        guard enabled, self.profile?.id == candidateProfile.id, ticket == generation,
              let recording = library.recording(recordingID), !recording.segments.isEmpty else { return }
        if !force, recording.voiceProfileChecked == candidateProfile.id { return }
        let audioURL = library.audioURL(recording)
        let audioFile = recording.audioFile
        let segments = recording.segments
        let fingerprint = try audioFingerprint(audioURL)
        let duration = try await audioDuration(audioURL)
        let speakers = Array(Set(segments.map(\.speaker).filter { !$0.isEmpty })).sorted()
        var candidates: [VoiceMatchCandidate] = []
        var means: [String: [Float]] = [:]
        var notes: [String] = []
        for speaker in speakers {
            try Task.checkCancellation()
            guard canApply(ticket, profileID: candidateProfile.id, recordingID: recordingID, audioFile: audioFile, fingerprint: fingerprint, segments: segments) else {
                throw CancellationError()
            }
            let windows = try VoiceWindowSelector.select(segments, speaker: speaker, duration: duration)
            guard windows.count >= VoiceMatchPolicy.minimumWindows else { notes.append("\(recording.speakerName(speaker)): too little clear speech"); continue }
            let vectors = try await embeddings(windows, audioURL: audioURL, generation: ticket)
            guard let scores = VoiceMatchPolicy.cosineScores(vectors, against: candidateProfile.vector) else {
                throw SpeakerEmbeddingError.invalidEmbedding
            }
            notes.append("\(recording.speakerName(speaker)): \(Int(((VoiceMatchPolicy.median(scores) ?? 0) * 100).rounded()))% (\(scores.count) clips)")
            guard let similarity = VoiceMatchPolicy.suggestionScore(scores) else { continue }
            candidates.append(VoiceMatchCandidate(speaker: speaker, similarity: similarity))
            means[speaker] = VoiceMatchPolicy.normalizedAverage(vectors)
        }
        try Task.checkCancellation()
        guard canApply(ticket, profileID: candidateProfile.id, recordingID: recordingID, audioFile: audioFile, fingerprint: fingerprint, segments: segments) else {
            throw CancellationError()
        }
        // When two speakers score close (often one person split in two), suggest the best one but do not tag it automatically.
        let unique = VoiceMatchPolicy.uniqueSuggestion(candidates)
        let winner = unique ?? candidates.max { $0.similarity < $1.similarity }
        var autoConfirmed = false
        try library.update(recordingID) { local in
            guard local.audioFile == audioFile, local.segments == segments else { return }
            let existing = local.voiceMatches ?? [:]
            var matches = Dictionary(uniqueKeysWithValues: existing.filter {
                $0.value.profileID == candidateProfile.id && ($0.value.confirmed || $0.value.rejected)
            })
            if let winner {
                let confirmedSpeaker = matches.first { $0.value.confirmed && !$0.value.rejected }?.key
                if confirmedSpeaker == nil || confirmedSpeaker == winner.speaker {
                    if matches[winner.speaker] == nil {
                        let strong = unique != nil && confirmedSpeaker == nil && winner.similarity >= VoiceMatchPolicy.autoConfirmThreshold
                        matches[winner.speaker] = SpeakerVoiceMatch(profileID: candidateProfile.id, similarity: winner.similarity, confirmed: strong)
                        autoConfirmed = strong
                    }
                }
            }
            local.voiceMatches = matches.isEmpty ? nil : matches
            local.voiceProfileChecked = candidateProfile.id
            local.voiceCheckNote = notes.isEmpty ? "No speakers to check" : notes.joined(separator: "\n")
        }
        if autoConfirmed, let winner, let mean = means[winner.speaker] { learn(mean) }
    }

    /// Blends a confirmed recording's voice into the profile. Older samples keep most of the weight.
    private func learn(_ vector: [Float]) {
        guard var current = profile else { return }
        let weight = Float(min(current.samples ?? 1, 9))
        guard let blended = VoiceMatchPolicy.normalized(zip(current.vector, vector).map { ($0 * weight + $1) / (weight + 1) }) else { return }
        current.vector = blended
        current.samples = (current.samples ?? 1) + 1
        guard let encoded = try? Self.encode(current),
              (try? Keychain.set(encoded, for: keychainAccount, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)) != nil else { return }
        profile = current
    }

    /// Rechecks every recording once after the matching rules change.
    func rescanIfRulesChanged() {
        let key = "voiceMatchVersion.\(keychainAccount)"
        guard enabled, UserDefaults.standard.integer(forKey: key) < VoiceMatchPolicy.version else { return }
        UserDefaults.standard.set(VoiceMatchPolicy.version, forKey: key)
        scanLibrary()
    }

    private func embeddings(
        _ windows: [VoiceAudioWindow],
        audioURL: URL,
        generation ticket: UInt64,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            guard ticket == generation else { throw CancellationError() }
            progress?(index + 1, windows.count)
            do {
                let vector = try await embedding.embedding(audioURL: audioURL, start: window.start)
                guard let vector = VoiceMatchPolicy.normalized(vector) else {
                    throw SpeakerEmbeddingError.invalidEmbedding
                }
                vectors.append(vector)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SpeakerEmbeddingError where error == .silentAudio || error == .tooShort {
                continue
            } catch {
                throw error
            }
        }
        return vectors
    }

    private func canApply(
        _ ticket: UInt64,
        profileID: UUID,
        recordingID: UUID,
        audioFile: String,
        fingerprint: AudioFingerprint,
        segments: [TranscriptSegment]
    ) -> Bool {
        let recording = library.recording(recordingID)
        let currentFingerprint = recording.flatMap { $0.audioFile == audioFile ? try? audioFingerprint(library.audioURL($0)) : nil }
        return VoiceMatchPolicy.canApply(
            capturedGeneration: ticket,
            currentGeneration: generation,
            profileID: profileID,
            currentProfileID: profile?.id,
            enabled: enabled,
            recordingExists: recording != nil,
            segmentsUnchanged: recording?.segments == segments,
            audioUnchanged: recording?.audioFile == audioFile && currentFingerprint == fingerprint
        )
    }

    private func enrollmentInputIsStable(recordingID: UUID, audioFile: String, fingerprint: AudioFingerprint, segments: [TranscriptSegment]) -> Bool {
        guard let recording = library.recording(recordingID), recording.audioFile == audioFile,
              recording.segments == segments else { return false }
        return (try? audioFingerprint(library.audioURL(recording))) == fingerprint
    }

    private func audioDuration(_ url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PocketError.message("The saved audio duration is invalid.") }
        return duration
    }

    private func audioFingerprint(_ url: URL) throws -> AudioFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw PocketError.message("The saved audio file is unavailable.") }
        return AudioFingerprint(size: size.intValue, modified: attributes[.modificationDate] as? Date, created: attributes[.creationDate] as? Date)
    }

    private var chooseAnotherRecordingError: PocketError {
        .message("Choose another Pocket recording with at least three clean 3-second speech windows from that speaker.")
    }

    private static func decodeProfile(_ saved: String) -> VoiceProfileCredential? {
        guard !saved.isEmpty else { return nil }
        do {
            guard let data = Data(base64Encoded: saved) else { throw PocketError.message("The saved voice profile is invalid.") }
            let stored = try JSONDecoder().decode(VoiceProfileCredential.self, from: data)
            guard stored.modelID == SpeakerEmbedding.modelID,
                  let vector = VoiceMatchPolicy.normalized(stored.vector) else {
                throw PocketError.message("The saved voice profile does not match the installed voice model.")
            }
            return VoiceProfileCredential(id: stored.id, modelID: stored.modelID, vector: vector, samples: stored.samples)
        } catch {
            return nil
        }
    }

    private static func encode(_ profile: VoiceProfileCredential) throws -> String {
        try JSONEncoder().encode(profile).base64EncodedString()
    }
}

private struct AudioFingerprint: Equatable {
    let size: Int
    let modified: Date?
    let created: Date?
}
