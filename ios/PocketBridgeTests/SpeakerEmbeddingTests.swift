import AVFoundation
import XCTest
@testable import PocketBridge

final class SpeakerEmbeddingTests: XCTestCase {
    func testDFTPowerMatchesKnownBinCenteredCosine() throws {
        let frame = (0..<SpeakerEmbedding.frameLength).map {
            Float(cos(2 * Double.pi * 20 * Double($0) / Double(SpeakerEmbedding.frameLength)))
        }
        let powers = try SpeakerEmbedding.powerSpectrum(
            frame: frame,
            window: [Float](repeating: 1, count: SpeakerEmbedding.frameLength)
        )

        XCTAssertEqual(powers.count, SpeakerEmbedding.spectrumBinCount)
        XCTAssertEqual(powers[20], 40_000, accuracy: 0.1)
        XCTAssertLessThan(powers[19], 0.1)
    }

    func testFrontendReturnsExpectedShapeAndZeroMeanBands() throws {
        let features = try SpeakerEmbedding.logMelFeatures(
            samples: [Float](repeating: 0, count: SpeakerEmbedding.clipSampleCount),
            melFilterbank: [Float](repeating: 0, count: SpeakerEmbedding.melBandCount * SpeakerEmbedding.spectrumBinCount)
        )

        XCTAssertEqual(features.count, SpeakerEmbedding.melBandCount * SpeakerEmbedding.frameCount)
        XCTAssertTrue(features.allSatisfy(\.isFinite))
        for band in 0..<SpeakerEmbedding.melBandCount {
            let values = features[(band * SpeakerEmbedding.frameCount)..<((band + 1) * SpeakerEmbedding.frameCount)]
            XCTAssertEqual(values.reduce(0.0) { $0 + Double($1) }, 0, accuracy: 0.001)
        }
    }

    func testSpeechBrainWindowAndBoundaryPaddingMatchReference() {
        let window = SpeakerEmbedding.hammingWindow()
        XCTAssertEqual(window[0], 0.08, accuracy: 0.000001)
        XCTAssertEqual(window[200], 1, accuracy: 0.000001)
        XCTAssertEqual(window[399], 0.08005676, accuracy: 0.000001)

        let samples: [Float] = [1, 2, 3]
        XCTAssertEqual(SpeakerEmbedding.centeredSample(samples: samples, center: 0, offset: 199), 0)
        XCTAssertEqual(SpeakerEmbedding.centeredSample(samples: samples, center: 0, offset: 200), 1)
        XCTAssertEqual(SpeakerEmbedding.centeredSample(samples: samples, center: 0, offset: 201), 2)
        XCTAssertEqual(SpeakerEmbedding.centeredSample(samples: samples, center: 0, offset: 202), 3)
    }

    func testSpeechBrainLogMelMatchesReferenceDBFloorAndMean() throws {
        var energies = [Float](repeating: 1e-10, count: SpeakerEmbedding.melBandCount * SpeakerEmbedding.frameCount)
        energies[0] = 1
        energies[1] = 10
        energies[2] = 100

        let features = try SpeakerEmbedding.normalizeMelEnergies(energies)

        XCTAssertEqual(features[0], 59.302326, accuracy: 0.0001)
        XCTAssertEqual(features[1], 69.302326, accuracy: 0.0001)
        XCTAssertEqual(features[2], 79.302326, accuracy: 0.0001)
        XCTAssertEqual(features[3], -0.697674, accuracy: 0.0001)
        XCTAssertEqual(features[SpeakerEmbedding.frameCount], 0, accuracy: 0.0001)
    }

    func testSilentAndTooShortAudioAreRejectedBeforeModelLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SpeakerEmbedding(modelDirectoryURL: root)

        let silenceURL = try writeAudio(to: root.appendingPathComponent("silence.caf"), seconds: 3, sample: { _, _ in 0 })
        do {
            _ = try await engine.embedding(audioURL: silenceURL, start: 0)
            XCTFail("Expected silence to be rejected.")
        } catch {
            XCTAssertEqual(error as? SpeakerEmbeddingError, .silentAudio)
        }

        let shortURL = try writeAudio(to: root.appendingPathComponent("short.caf"), seconds: 2.9, sample: { index, _ in
            sin(Float(2 * Double.pi * 140 * Double(index) / 16_000)) * 0.2
        })
        do {
            _ = try await engine.embedding(audioURL: shortURL, start: 0)
            XCTFail("Expected a short clip to be rejected.")
        } catch {
            XCTAssertEqual(error as? SpeakerEmbeddingError, .tooShort)
        }
    }

    func testBundledModelEmbedsNativeAndResampledAudioWhenAvailable() async throws {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("VoiceModel", isDirectory: true),
            Bundle(for: Self.self).bundleURL.appendingPathComponent("VoiceModel", isDirectory: true)
        ]
        guard let modelDirectory = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("speaker.mlmodelc").path)
        }) else {
            throw XCTSkip("VoiceModel is not in this test bundle.")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SpeakerEmbedding(modelDirectoryURL: modelDirectory)
        for (sampleRate, channels) in [(16_000.0, AVAudioChannelCount(1)), (44_100.0, 2), (48_000.0, 2)] {
            let audioURL = try writeAudio(
                to: root.appendingPathComponent("speech-\(Int(sampleRate)).caf"),
                seconds: 4,
                sampleRate: sampleRate,
                channels: channels
            ) { index, channel in
                let time = Double(index) / sampleRate
                let voice = 0.20 * sin(2 * Double.pi * 137 * time) + 0.08 * sin(2 * Double.pi * 274 * time)
                return Float(voice * (channel == 0 ? 1 : 0.8))
            }

            let vector = try await engine.embedding(audioURL: audioURL, start: 0.5)
            XCTAssertEqual(vector.count, SpeakerEmbedding.embeddingSize)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            XCTAssertEqual(norm, 1, accuracy: 0.0001)
        }
    }

    private func writeAudio(
        to url: URL,
        seconds: Double,
        sampleRate: Double = 16_000,
        channels: AVAudioChannelCount = 1,
        sample: (Int, Int) -> Float
    ) throws -> URL {
        let count = Int(seconds * sampleRate)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for index in 0..<count {
                channelData[channel][index] = sample(index, channel)
            }
        }
        try file.write(from: buffer)
        return url
    }
}
