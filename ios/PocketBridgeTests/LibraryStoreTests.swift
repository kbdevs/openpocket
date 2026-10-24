import Foundation
import XCTest
@testable import PocketBridge

final class LibraryStoreTests: XCTestCase {
    @MainActor
    func testImportUpdatePersistenceAndDelete() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        let source = root.appendingPathComponent("voice.wav")
        let audio = silentWAV()
        try audio.write(to: source)

        let library = LibraryStore(directory: libraryDirectory)
        let id = try await library.importAudio(source)
        let imported = try XCTUnwrap(library.recording(id))
        XCTAssertEqual(imported.title, "voice")
        XCTAssertEqual(imported.source, "Import")
        XCTAssertEqual(try Data(contentsOf: library.audioURL(imported)), audio)
        XCTAssertEqual(imported.duration, 1, accuracy: 0.05)

        try library.update(id) { $0.folder = "Work" }
        let reopened = LibraryStore(directory: libraryDirectory)
        XCTAssertEqual(reopened.recording(id)?.folder, "Work")

        let audioURL = reopened.audioURL(try XCTUnwrap(reopened.recording(id)))
        try reopened.delete(id)
        XCTAssertNil(reopened.recording(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(LibraryStore(directory: libraryDirectory).recordings.isEmpty)
    }

    @MainActor
    func testFailedIndexWriteLeavesInMemoryRecordingUnchanged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        let source = root.appendingPathComponent("voice.wav")
        try silentWAV().write(to: source)

        let library = LibraryStore(directory: libraryDirectory)
        let id = try await library.importAudio(source)
        let index = libraryDirectory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try library.update(id) { $0.title = "Changed" })
        XCTAssertEqual(library.recording(id)?.title, "voice")
    }

    @MainActor
    func testCorruptIndexCannotBeOverwrittenByImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("library.json")
        let corrupt = Data("incomplete index".utf8)
        try corrupt.write(to: index)
        let library = LibraryStore(directory: root)
        XCTAssertNotNil(library.error)
        let source = root.appendingPathComponent("source.wav")
        try silentWAV().write(to: source)
        do { _ = try await library.importAudio(source); XCTFail("Import must not replace an unreadable index") }
        catch { XCTAssertEqual(try Data(contentsOf: index), corrupt) }
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
