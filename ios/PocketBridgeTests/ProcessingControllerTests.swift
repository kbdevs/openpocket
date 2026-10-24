import Foundation
import XCTest
@testable import PocketBridge

final class ProcessingControllerTests: XCTestCase {
    @MainActor
    func testSpeechOnlyBuildCompletesWithoutCallingNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousMode = UserDefaults.standard.string(forKey: "aiMode")
        UserDefaults.standard.set("direct", forKey: "aiMode")
        defer { UserDefaults.standard.set(previousMode, forKey: "aiMode") }
        let source = root.appendingPathComponent("voice.mp3")
        try Data("ID3test audio".utf8).write(to: source)
        let library = LibraryStore(directory: root.appendingPathComponent("Recordings"))
        let id = try await library.importAudio(source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProcessingHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ProcessingHTTPStub.handler = nil }
        var speechCalls = 0
        var notesCalls = 0
        ProcessingHTTPStub.handler = { request in
            if request.url?.host != "api.deepgram.com" { notesCalls += 1; return (500, Data()) }
            speechCalls += 1
            return (200, Data(#"{"metadata":{"duration":1},"results":{"channels":[{"alternatives":[{"transcript":"Ready."}]}],"utterances":[{"start":0,"end":1,"speaker":0,"transcript":"Ready."}]}}"#.utf8))
        }
        let client = DirectAIClient(deepgramKey: "test-speech-key", openRouterKey: "", session: session)
        let processor = ProcessingController(library: library, directClient: client)
        processor.process(id)
        try await waitForIdle(processor, id)
        XCTAssertEqual(library.recording(id)?.status, "complete")
        XCTAssertNil(library.recording(id)?.error)
        XCTAssertEqual(library.recording(id)?.segments.first?.text, "Ready.")
        XCTAssertEqual(library.recording(id)?.speechComplete, true)
        XCTAssertEqual(speechCalls, 1)
        XCTAssertEqual(notesCalls, 0)
    }

    @MainActor
    func testNotesRetryAndRelaunchKeepCompletedSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousMode = UserDefaults.standard.string(forKey: "aiMode")
        UserDefaults.standard.set("direct", forKey: "aiMode")
        defer { UserDefaults.standard.set(previousMode, forKey: "aiMode") }
        let source = root.appendingPathComponent("voice.mp3")
        try Data("ID3fake audio for mocked transport".utf8).write(to: source)
        let directory = root.appendingPathComponent("Recordings")
        let library = LibraryStore(directory: directory)
        let id = try await library.importAudio(source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProcessingHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ProcessingHTTPStub.handler = nil }
        let client = DirectAIClient(deepgramKey: "test-speech-key", openRouterKey: "test-notes-key", session: session)
        var speechCalls = 0
        var notesCalls = 0
        ProcessingHTTPStub.handler = { request in
            if request.url?.host == "api.deepgram.com" {
                speechCalls += 1
                return (200, Data(#"{"metadata":{"duration":2},"results":{"channels":[{"detected_language":"en","alternatives":[{"transcript":"Send the draft","words":[{"word":"Send","punctuated_word":"Send","start":0,"end":0.4,"speaker":0},{"word":"the","start":0.4,"end":0.6,"speaker":0},{"word":"draft","start":0.6,"end":1.2,"speaker":0}]}]}],"utterances":[{"start":0,"end":1.2,"speaker":0,"transcript":"Send the draft"}]}}"#.utf8))
            }
            notesCalls += 1
            if notesCalls == 1 { return (503, Data()) }
            return (200, Data(#"{"choices":[{"message":{"content":"{\"title\":\"Plan\",\"summary\":\"Draft due\",\"actions\":[]}"},"finish_reason":"stop"}]}"#.utf8))
        }
        let processor = ProcessingController(library: library, directClient: client)
        processor.process(id)
        try await waitForIdle(processor, id)
        XCTAssertEqual(library.recording(id)?.status, "failed")
        XCTAssertEqual(library.recording(id)?.speechComplete, true)
        XCTAssertEqual(library.recording(id)?.segments.first?.text, "Send the draft")
        let reopened = LibraryStore(directory: directory)
        try reopened.update(id) { $0.segments[0].text = "Send the edited draft"; $0.title = "My title"; $0.titleIsLocal = true }
        let retry = ProcessingController(library: reopened, directClient: client)
        retry.process(id)
        try await waitForIdle(retry, id)
        XCTAssertEqual(speechCalls, 1)
        XCTAssertEqual(notesCalls, 2)
        XCTAssertEqual(reopened.recording(id)?.status, "complete")
        XCTAssertEqual(reopened.recording(id)?.summary, "Draft due")
        XCTAssertEqual(reopened.recording(id)?.title, "My title")
        XCTAssertEqual(reopened.recording(id)?.segments.first?.text, "Send the edited draft")
    }

    func testEmptySpeechCheckpointSurvivesEncoding() throws {
        var recording = Recording(title: "Silence", audioFile: "voice.wav")
        recording.speechComplete = true
        let reopened = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(recording))
        XCTAssertTrue(reopened.hasSpeechCheckpoint)
        XCTAssertTrue(reopened.segments.isEmpty)
    }

    @MainActor
    private func waitForIdle(_ processor: ProcessingController, _ id: UUID) async throws {
        for _ in 0..<250 {
            if !processor.active.contains(id) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Processing did not finish")
    }
}

private final class ProcessingHTTPStub: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
