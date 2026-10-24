import XCTest
@testable import PocketBridge

final class ModelsTests: XCTestCase {
    func testActionItemDefaultsDoneToFalseWhenDecodingOlderData() throws {
        let data = Data(#"{"id":"a1","text":"Send notes"}"#.utf8)
        let item = try JSONDecoder().decode(ActionItem.self, from: data)

        XCTAssertFalse(item.done)
    }

    func testRecordingSearchAndTranscriptText() {
        let recording = Recording(
            title: "Planning",
            audioFile: "planning.m4a",
            segments: [TranscriptSegment(id: "s1", speaker: "spk_1", start: 65, end: 72, text: "Ship the update")],
            summary: "Release planning",
            speakerNames: ["spk_1": "Sam"]
        )

        XCTAssertTrue(recording.searchableText.contains("Ship the update"))
        XCTAssertEqual(recording.transcriptText, "[1:05] Sam: Ship the update")
        XCTAssertEqual(recording.namedSegments.first?.speaker, "Sam")
    }

    func testTimeLabelsHandleUntrustedValues() {
        XCTAssertEqual(timeLabel(-1), "0:00")
        XCTAssertEqual(timeLabel(.infinity), "0:00")
        XCTAssertEqual(timeLabel(.nan), "0:00")
        XCTAssertEqual(timeLabel(3_661), "1:01:01")
        XCTAssertFalse(timeLabel(Double.greatestFiniteMagnitude).isEmpty)
    }

    func testLaterServerResultKeepsLocalTranscriptAndTitleEdits() throws {
        let data = Data(#"{"id":"job","status":"processing","segments":[{"id":"0","speaker":"Speaker 1","start":0,"end":1,"text":"Original"}]}"#.utf8)
        var remote = try JSONDecoder().decode(RemoteRecording.self, from: data)
        var recording = Recording(title: "Original title", audioFile: "voice.wav")
        recording.applyRemote(remote)
        XCTAssertEqual(recording.segments.first?.text, "Original")
        recording.segments[0].text = "Corrected locally"
        recording.title = "Edited title"; recording.titleIsLocal = true
        remote.status = "complete"; remote.summary = "Notes ready"; remote.title = "Server title"
        recording.applyRemote(remote)
        XCTAssertEqual(recording.segments.first?.text, "Corrected locally")
        XCTAssertEqual(recording.title, "Edited title")
        XCTAssertEqual(recording.summary, "Notes ready")
        XCTAssertEqual(recording.status, "complete")
    }

    func testCompletedServerNotesReplaceTheDefaultTitle() throws {
        var remote = try JSONDecoder().decode(RemoteRecording.self, from: Data(#"{"id":"job","status":"processing","title":"Pocket 2026-10-24 · 20261024103000.mp3"}"#.utf8))
        var recording = Recording(title: "Pocket 2026-10-24 · 20261024103000.mp3", audioFile: "voice.wav")
        recording.applyRemote(remote)
        XCTAssertEqual(recording.title, "Pocket 2026-10-24 · 20261024103000.mp3")
        remote.status = "complete"; remote.title = "Launch Plan Review"
        recording.applyRemote(remote)
        XCTAssertEqual(recording.title, "Launch Plan Review")
    }

    func testResumingDoesNotReplaceRenamedTitleOrLocalNotes() throws {
        let data = Data(#"{"id":"job","status":"complete","title":"Old server title","summary":"Old server notes","actions":[{"id":"0","text":"Server action"}]}"#.utf8)
        let remote = try JSONDecoder().decode(RemoteRecording.self, from: data)
        var recording = Recording(title: "Renamed before resume", audioFile: "voice.wav")
        recording.summary = "Notes made from corrected transcript"
        recording.actions = [ActionItem(id: "0", text: "User action", done: true)]
        recording.summaryIsLocal = true; recording.actionsAreLocal = true; recording.titleIsLocal = true
        recording.applyRemote(remote)
        XCTAssertEqual(recording.title, "Renamed before resume")
        XCTAssertEqual(recording.summary, "Notes made from corrected transcript")
        XCTAssertEqual(recording.actions.first?.text, "User action")
        XCTAssertEqual(recording.actions.first?.done, true)
    }
}
