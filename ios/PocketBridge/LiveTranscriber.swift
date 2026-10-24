import Foundation
import Observation

/// Streams the MP3 that Pocket sends while it records to Deepgram's live API.
/// The saved recording is still synced and processed normally afterwards.
@MainActor @Observable
final class LiveTranscriber {
    private(set) var lines: [String] = []
    private(set) var interim = ""
    private(set) var failed: String?
    private var socket: URLSessionWebSocketTask?

    init?(deepgramKey: String) {
        guard !deepgramKey.isEmpty,
              let url = URL(string: "wss://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true&interim_results=true") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Token \(deepgramKey)", forHTTPHeaderField: "Authorization")
        socket = URLSession.shared.webSocketTask(with: request)
        socket?.resume()
        receive()
    }

    func send(_ audio: Data) {
        socket?.send(.data(audio)) { _ in }
    }

    func finish() {
        socket?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
    }

    func cancel() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)): self.apply(Data(text.utf8)); self.receive()
                case .success(.data(let data)): self.apply(data); self.receive()
                case .success: self.receive()
                case .failure(let error): if self.socket != nil, self.lines.isEmpty { self.failed = error.localizedDescription }
                }
            }
        }
    }

    private func apply(_ data: Data) {
        guard let result = try? JSONDecoder().decode(LiveResult.self, from: data),
              let alternative = result.channel?.alternatives.first else { return }
        let text = alternative.transcript.trimmingCharacters(in: .whitespaces)
        guard result.is_final == true else { interim = text; return }
        interim = ""
        guard !text.isEmpty else { return }
        let speaker = alternative.words?.first?.speaker.map { "Speaker \($0 + 1): " } ?? ""
        lines.append(speaker + text)
    }

    private struct LiveResult: Decodable {
        struct Channel: Decodable { let alternatives: [Alternative] }
        struct Alternative: Decodable { let transcript: String; let words: [Word]? }
        struct Word: Decodable { let speaker: Int? }
        let channel: Channel?
        let is_final: Bool?
    }
}
