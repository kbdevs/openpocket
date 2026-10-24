import XCTest
import AVFoundation
@testable import PocketBridge

final class AudioUploadTests: XCTestCase {
    func testAIFFAndCAFBecomeM4AUploads() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in ["aiff", "caf"] {
            let source = root.appendingPathComponent("silence.\(ext)")
            try writeSilence(source)
            let output = try await BackendClient.prepareAudio(source)
            defer { try? FileManager.default.removeItem(at: output) }
            XCTAssertEqual(output.pathExtension, "m4a")
            let data = try Data(contentsOf: output)
            XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp")
            let duration = try await AVURLAsset(url: output).load(.duration).seconds
            XCTAssertEqual(duration, 1, accuracy: 0.1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @MainActor
    func testLegacyRecordingRecoveryDoesNotDuplicateAfterRelaunch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        let id = UUID()
        let source = root.appendingPathComponent("Microphone-\(id.uuidString).m4a")
        try writeSilence(source)
        let original = try Data(contentsOf: source)
        let first = LibraryStore(directory: directory)
        await first.recoverLegacyRecordings()
        XCTAssertEqual(first.recordings.count, 1)
        XCTAssertEqual(first.recordings.first?.id, id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        // Simulate a stop after saving the index but before removing the source.
        try original.write(to: source)
        let reopened = LibraryStore(directory: directory)
        await reopened.recoverLegacyRecordings()
        XCTAssertEqual(reopened.recordings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    private func writeSilence(_ url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 16_000)
        let settings: [String: Any] = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
