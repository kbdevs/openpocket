import Foundation
import Security
import XCTest
@testable import PocketBridge

final class VoiceMatchingTests: XCTestCase {
    func testNormalizedVectorsRequireFiniteNonzero192DimensionsAndUseCosinePolicy() throws {
        let profile = vector(1, 0)
        let matching = [vector(1, 0), vector(0.8, 0.6), vector(0.7, sqrt(0.51))]
        let nonmatching = [vector(0, 1), vector(0.1, sqrt(0.99)), vector(0.2, sqrt(0.96))]
        XCTAssertNotNil(VoiceMatchPolicy.suggestionScore(matching, against: profile))
        XCTAssertNil(VoiceMatchPolicy.suggestionScore(nonmatching, against: profile))
        XCTAssertNil(VoiceMatchPolicy.suggestionScore(Array(matching.prefix(2)), against: profile))
        XCTAssertNil(VoiceMatchPolicy.normalized([Float](repeating: 0, count: 192)))
        XCTAssertNil(VoiceMatchPolicy.normalized([Float](repeating: 1, count: 191)))
        var invalid = vector(1, 0)
        invalid[0] = .infinity
        XCTAssertNil(VoiceMatchPolicy.normalized(invalid))
        XCTAssertNil(VoiceMatchPolicy.normalizedAverage([vector(1, 0), invalid]))
        XCTAssertNil(VoiceMatchPolicy.cosineScores([vector(1, 0), invalid], against: profile))
    }

    func testSimilarStrongGroupsSuppressThePossibleMatch() throws {
        let first = 0.88, second = 0.87, distinct = 0.74

        XCTAssertNil(VoiceMatchPolicy.uniqueSuggestion([
            VoiceMatchCandidate(speaker: "Speaker 1", similarity: first),
            VoiceMatchCandidate(speaker: "Speaker 2", similarity: second)
        ]))
        XCTAssertEqual(VoiceMatchPolicy.uniqueSuggestion([
            VoiceMatchCandidate(speaker: "Speaker 1", similarity: first),
            VoiceMatchCandidate(speaker: "Speaker 2", similarity: distinct)
        ])?.speaker, "Speaker 1")
    }

    func testWindowSelectionTrimsEdgesRejectsOverlapAndSkipsShortOrSilentWindows() throws {
        let segments = [
            segment("self", "Speaker 1", 0, 12.2),
            segment("other", "Speaker 2", 4, 5)
        ]
        let windows = try VoiceWindowSelector.select(segments, speaker: "Speaker 1", duration: 12.2)
        XCTAssertEqual(windows.map(\.start), [0.1, 6.1, 9.1])
        XCTAssertTrue(zip(windows, windows.dropFirst()).allSatisfy { pair in pair.0.end <= pair.1.start })
        XCTAssertTrue(windows.allSatisfy { $0.end <= 4 || $0.start >= 5 })

        let short = try VoiceWindowSelector.select([segment("short", "Speaker 1", 0, 3.1)], speaker: "Speaker 1", duration: 3.1)
        XCTAssertTrue(short.isEmpty)
        XCTAssertNil(VoiceMatchPolicy.normalized([Float](repeating: 0, count: 192)))
        XCTAssertThrowsError(try VoiceWindowSelector.select(
            [segment("bad", "Speaker 1", 9, 11)], speaker: "Speaker 1", duration: 10
        ))
    }

    func testShortPhrasesFromOneSpeakerJoinUnlessSomeoneSpeaksBetween() throws {
        let phrases = (0..<6).map { segment("p\($0)", "Speaker 1", Double($0) * 2.2, Double($0) * 2.2 + 2) }
        XCTAssertEqual(try VoiceWindowSelector.select(phrases, speaker: "Speaker 1", duration: 14).count, 4)

        let interrupted = [segment("a", "Speaker 1", 0, 2), segment("b", "Speaker 2", 2.1, 2.4), segment("c", "Speaker 1", 2.5, 4.5)]
        XCTAssertTrue(try VoiceWindowSelector.select(interrupted, speaker: "Speaker 1", duration: 5).isEmpty)
    }

    func testOlderRecordingsDecodeVoiceMetadataAsNilAndManualNamesWin() throws {
        var old = Recording(
            title: "Older Pocket recording",
            audioFile: "recording.m4a",
            segments: [segment("one", "Speaker 1", 0, 1), segment("two", "Speaker 2", 1, 2)],
            speakerNames: ["Speaker 1": "Sam"],
            voiceMatches: [
                "Speaker 1": SpeakerVoiceMatch(profileID: UUID(), similarity: 0.92, confirmed: true),
                "Speaker 2": SpeakerVoiceMatch(profileID: UUID(), similarity: 0.88)
            ]
        )
        old.voiceProfileChecked = UUID()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "voiceMatches")
        object.removeValue(forKey: "voiceProfileChecked")
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.voiceMatches)
        XCTAssertNil(decoded.voiceProfileChecked)

        XCTAssertEqual(old.speakerName("Speaker 1"), "Sam")
        XCTAssertEqual(old.speakerName("Speaker 2"), "Speaker 2")
        old.voiceMatches?["Speaker 2"]?.confirmed = true
        XCTAssertEqual(old.speakerName("Speaker 2"), "You")
        XCTAssertEqual(old.segments[1].speaker, "Speaker 2")
    }

    func testStaleGenerationOrChangedInputsCannotApplyResults() {
        let profileID = UUID()
        func canApply(
            generation: UInt64 = 7,
            currentGeneration: UInt64 = 7,
            currentProfileID: UUID? = profileID,
            enabled: Bool = true,
            recordingExists: Bool = true,
            segmentsUnchanged: Bool = true,
            audioUnchanged: Bool = true
        ) -> Bool {
            VoiceMatchPolicy.canApply(
                capturedGeneration: generation,
                currentGeneration: currentGeneration,
                profileID: profileID,
                currentProfileID: currentProfileID,
                enabled: enabled,
                recordingExists: recordingExists,
                segmentsUnchanged: segmentsUnchanged,
                audioUnchanged: audioUnchanged
            )
        }

        XCTAssertTrue(canApply())
        XCTAssertFalse(canApply(currentGeneration: 8))
        XCTAssertFalse(canApply(currentProfileID: UUID()))
        XCTAssertFalse(canApply(enabled: false))
        XCTAssertFalse(canApply(recordingExists: false))
        XCTAssertFalse(canApply(segmentsUnchanged: false))
        XCTAssertFalse(canApply(audioUnchanged: false))
    }

    @MainActor
    func testDeleteProfileClearsKeychainAndOnlyVoiceMetadata() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "voice-test-\(UUID().uuidString)"
        defer {
            try? Keychain.set("", for: account, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
            UserDefaults.standard.removeObject(forKey: "voiceRecognitionEnabled.\(account)")
        }
        let (library, id, audioURL) = try await makeLibrary(root: root)
        let profileID = UUID()
        try library.update(id) { recording in
            recording.summary = "Keep this summary"
            recording.segments = [segment("one", "Speaker 1", 0, 1)]
            recording.speakerNames["Speaker 1"] = "Sam"
            recording.voiceMatches = ["Speaker 1": SpeakerVoiceMatch(profileID: profileID, similarity: 0.93, confirmed: true)]
            recording.voiceProfileChecked = profileID
        }
        let credential = try profileCredential(profileID: profileID)
        try Keychain.set(try JSONEncoder().encode(credential).base64EncodedString(), for: account, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        let store = VoiceProfileStore(library: library, keychainAccount: account)
        XCTAssertTrue(store.hasProfile)
        XCTAssertFalse(store.enabled)
        store.enabled = true
        XCTAssertTrue(store.enabled)

        try store.deleteProfile()

        XCTAssertFalse(store.hasProfile)
        XCTAssertFalse(store.enabled)
        XCTAssertEqual(Keychain.value(for: account), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        let reopened = try XCTUnwrap(LibraryStore(directory: root.appendingPathComponent("Recordings")).recording(id))
        XCTAssertNil(reopened.voiceMatches)
        XCTAssertNil(reopened.voiceProfileChecked)
        XCTAssertEqual(reopened.speakerNames["Speaker 1"], "Sam")
        XCTAssertEqual(reopened.segments.first?.text, "Transcript")
        XCTAssertEqual(reopened.summary, "Keep this summary")
    }

    @MainActor
    func testDeleteWithUnreadableEmptyLibraryKeepsCredentialAndIndex() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "voice-test-\(UUID().uuidString)"
        defer {
            try? Keychain.set("", for: account, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
            UserDefaults.standard.removeObject(forKey: "voiceRecognitionEnabled.\(account)")
        }
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("library.json")
        let invalidIndex = Data("unreadable library index".utf8)
        try invalidIndex.write(to: index)
        let library = LibraryStore(directory: directory)
        XCTAssertTrue(library.recordings.isEmpty)

        let profileID = UUID()
        let saved = try JSONEncoder().encode(profileCredential(profileID: profileID)).base64EncodedString()
        try Keychain.set(saved, for: account, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        let store = VoiceProfileStore(library: library, keychainAccount: account)

        XCTAssertThrowsError(try store.deleteProfile())
        XCTAssertTrue(store.hasProfile)
        XCTAssertEqual(Keychain.value(for: account), saved)
        XCTAssertEqual(try Data(contentsOf: index), invalidIndex)
    }

    @MainActor
    func testSaveVoiceEnrollmentReplacesAllVoiceMetadataAndReopens() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, selectedID, _) = try await makeLibrary(root: root)
        let otherID = try await library.importAudio(root.appendingPathComponent("voice.wav"), title: "Other recording")
        let oldSelectedProfileID = UUID()
        let oldOtherProfileID = UUID()
        try library.update(selectedID) { recording in
            recording.summary = "Keep this summary"
            recording.speakerNames["Speaker 1"] = "Sam"
            recording.voiceMatches = ["Speaker 1": SpeakerVoiceMatch(profileID: oldSelectedProfileID, similarity: 0.81, confirmed: true)]
            recording.voiceProfileChecked = oldSelectedProfileID
        }
        try library.update(otherID) { recording in
            recording.voiceMatches = ["Speaker 2": SpeakerVoiceMatch(profileID: oldOtherProfileID, similarity: 0.82, rejected: true)]
            recording.voiceProfileChecked = oldOtherProfileID
        }

        let newProfileID = UUID()
        let enrollment = SpeakerVoiceMatch(profileID: newProfileID, similarity: 0.96, confirmed: true)
        try library.saveVoiceEnrollment(recordingID: selectedID, speaker: "Speaker 2", match: enrollment)

        let selected = try XCTUnwrap(library.recording(selectedID))
        let other = try XCTUnwrap(library.recording(otherID))
        XCTAssertEqual(selected.voiceMatches, ["Speaker 2": enrollment])
        XCTAssertEqual(selected.voiceProfileChecked, newProfileID)
        XCTAssertEqual(selected.speakerNames["Speaker 1"], "Sam")
        XCTAssertEqual(selected.summary, "Keep this summary")
        XCTAssertNil(other.voiceMatches)
        XCTAssertNil(other.voiceProfileChecked)

        let reopened = LibraryStore(directory: library.directory)
        XCTAssertEqual(reopened.recording(selectedID)?.voiceMatches, ["Speaker 2": enrollment])
        XCTAssertEqual(reopened.recording(selectedID)?.voiceProfileChecked, newProfileID)
        XCTAssertNil(reopened.recording(otherID)?.voiceMatches)
        XCTAssertNil(reopened.recording(otherID)?.voiceProfileChecked)
    }

    @MainActor
    func testFailedVoiceEnrollmentWriteKeepsAllInMemoryVoiceMetadata() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, selectedID, _) = try await makeLibrary(root: root)
        let otherID = try await library.importAudio(root.appendingPathComponent("voice.wav"), title: "Other recording")
        let selectedMatches = ["Speaker 1": SpeakerVoiceMatch(profileID: UUID(), similarity: 0.91, confirmed: true)]
        let otherMatches = ["Speaker 2": SpeakerVoiceMatch(profileID: UUID(), similarity: 0.77, rejected: true)]
        let selectedChecked = UUID()
        let otherChecked = UUID()
        try library.update(selectedID) { recording in
            recording.speakerNames["Speaker 1"] = "Sam"
            recording.voiceMatches = selectedMatches
            recording.voiceProfileChecked = selectedChecked
        }
        try library.update(otherID) { recording in
            recording.voiceMatches = otherMatches
            recording.voiceProfileChecked = otherChecked
        }
        let index = library.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try library.saveVoiceEnrollment(
            recordingID: selectedID,
            speaker: "Speaker 2",
            match: SpeakerVoiceMatch(profileID: UUID(), similarity: 0.96, confirmed: true)
        ))

        XCTAssertEqual(library.recording(selectedID)?.voiceMatches, selectedMatches)
        XCTAssertEqual(library.recording(selectedID)?.voiceProfileChecked, selectedChecked)
        XCTAssertEqual(library.recording(selectedID)?.speakerNames["Speaker 1"], "Sam")
        XCTAssertEqual(library.recording(otherID)?.voiceMatches, otherMatches)
        XCTAssertEqual(library.recording(otherID)?.voiceProfileChecked, otherChecked)
    }

    @MainActor
    func testLoadedCredentialPrunesStaleMatchesAndKeepsCurrentDecisions() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "voice-test-\(UUID().uuidString)"
        defer {
            try? Keychain.set("", for: account, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
            UserDefaults.standard.removeObject(forKey: "voiceRecognitionEnabled.\(account)")
        }
        let (library, firstID, _) = try await makeLibrary(root: root)
        let secondID = try await library.importAudio(root.appendingPathComponent("voice.wav"), title: "Other recording")
        let activeProfileID = UUID()
        let staleProfileID = UUID()
        let confirmed = SpeakerVoiceMatch(profileID: activeProfileID, similarity: 0.93, confirmed: true)
        let rejected = SpeakerVoiceMatch(profileID: activeProfileID, similarity: 0.74, rejected: true)
        try library.update(firstID) { recording in
            recording.segments = [segment("one", "Speaker 1", 0, 1), segment("two", "Speaker 2", 1, 2)]
            recording.speakerNames["Speaker 1"] = "Sam"
            recording.voiceMatches = [
                "Speaker 1": confirmed,
                "Speaker 2": SpeakerVoiceMatch(profileID: staleProfileID, similarity: 0.89, confirmed: true),
                "Speaker 3": rejected
            ]
            recording.voiceProfileChecked = staleProfileID
        }
        try library.update(secondID) { recording in
            recording.voiceMatches = ["Speaker 1": SpeakerVoiceMatch(profileID: staleProfileID, similarity: 0.88)]
            recording.voiceProfileChecked = activeProfileID
        }
        let saved = try JSONEncoder().encode(profileCredential(profileID: activeProfileID)).base64EncodedString()
        try Keychain.set(saved, for: account, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

        let reopened = LibraryStore(directory: library.directory)
        let store = VoiceProfileStore(library: reopened, keychainAccount: account)

        XCTAssertTrue(store.hasProfile)
        XCTAssertEqual(Keychain.value(for: account), saved)
        let first = try XCTUnwrap(reopened.recording(firstID))
        let second = try XCTUnwrap(reopened.recording(secondID))
        XCTAssertEqual(first.voiceMatches, ["Speaker 1": confirmed, "Speaker 3": rejected])
        XCTAssertNil(first.voiceProfileChecked)
        XCTAssertEqual(first.speakerNames["Speaker 1"], "Sam")
        XCTAssertNil(second.voiceMatches)
        XCTAssertEqual(second.voiceProfileChecked, activeProfileID)

        let persisted = LibraryStore(directory: library.directory)
        XCTAssertEqual(persisted.recording(firstID)?.voiceMatches, first.voiceMatches)
        XCTAssertNil(persisted.recording(firstID)?.voiceProfileChecked)
        XCTAssertNil(persisted.recording(secondID)?.voiceMatches)
        XCTAssertEqual(persisted.recording(secondID)?.voiceProfileChecked, activeProfileID)
    }

    private func vector(_ x: Double, _ y: Double) -> [Float] {
        [Float(x), Float(y)] + [Float](repeating: 0, count: 190)
    }

    private func segment(_ id: String, _ speaker: String, _ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(id: id, speaker: speaker, start: start, end: end, text: "Transcript")
    }

    private func profileCredential(profileID: UUID) throws -> VoiceProfileCredential {
        VoiceProfileCredential(
            id: profileID,
            modelID: SpeakerEmbedding.modelID,
            vector: try XCTUnwrap(VoiceMatchPolicy.normalized([Float](repeating: 1, count: 192)))
        )
    }

    @MainActor
    private func makeLibrary(root: URL) async throws -> (LibraryStore, UUID, URL) {
        let source = root.appendingPathComponent("voice.wav")
        try silentWAV().write(to: source)
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        let library = LibraryStore(directory: directory)
        let id = try await library.importAudio(source)
        let recording = try XCTUnwrap(library.recording(id))
        return (library, id, library.audioURL(recording))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func silentWAV() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(32_036); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(32_000)
        data.append(Data(count: 32_000))
        return data
    }
}
