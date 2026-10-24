import Foundation
import XCTest
@testable import PocketBridge

final class LibraryFeaturesTests: XCTestCase {
    @MainActor
    func testRenamingAPersonUpdatesEveryRecordingAndMergesNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = UUID(), second = UUID()
        var one = Recording(id: first, title: "One", audioFile: "\(first.uuidString).wav")
        one.speakerNames = ["Speaker 1": "Sam", "Speaker 2": "Alex"]
        var two = Recording(id: second, title: "Two", audioFile: "\(second.uuidString).wav")
        two.speakerNames = ["Speaker 1": "Samuel"]
        try JSONEncoder().encode([one, two]).write(to: directory.appendingPathComponent("library.json"))
        let library = LibraryStore(directory: directory)
        XCTAssertEqual(Set(library.people.map(\.name)), ["Sam", "Alex", "Samuel"])

        try library.renamePerson("Samuel", to: "Sam")
        XCTAssertEqual(library.recording(second)?.speakerNames["Speaker 1"], "Sam")
        XCTAssertEqual(library.people.first?.name, "Sam")
        XCTAssertEqual(library.people.first?.count, 2)
        XCTAssertEqual(library.recordings(with: "Sam").map(\.id).sorted { $0.uuidString < $1.uuidString }, [first, second].sorted { $0.uuidString < $1.uuidString })
    }

    func testAskContextPutsMatchingTranscriptsFirstAndStaysUnderTheLimit() {
        var pricing = Recording(title: "Pricing", audioFile: "a.wav")
        pricing.summary = "Discussed plans."
        pricing.segments = [TranscriptSegment(id: "0", speaker: "Speaker 1", start: 0, end: 1, text: "The pricing will be ten dollars.")]
        var other = Recording(title: "Standup", audioFile: "b.wav")
        other.summary = String(repeating: "x", count: 400)
        let context = LibraryAsk.context([other, pricing], question: "What did we decide about pricing?", limitBytes: 2_000)
        XCTAssertTrue(context.first?.speaker.hasPrefix("Pricing") == true)
        XCTAssertTrue(context.contains { $0.text == "The pricing will be ten dollars." })
        XCTAssertLessThanOrEqual(context.reduce(0) { $0 + $1.speaker.utf8.count + $1.text.utf8.count + 80 }, 2_000)
    }

    func testCustomTemplateValueCarriesTheInstruction() {
        let saved = NotesTemplates.custom
        defer { NotesTemplates.custom = saved }
        let template = CustomTemplate(name: "Bullets", prompt: "Bullet points only.")
        NotesTemplates.custom = [template]
        XCTAssertEqual(NotesTemplates.value(for: "lecture"), "lecture")
        XCTAssertEqual(NotesTemplates.value(for: template.id.uuidString), "custom:Bullet points only.")
        XCTAssertEqual(NotesTemplates.value(for: "missing"), "meeting")
    }
}
