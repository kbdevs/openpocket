import AVFoundation
import Accelerate
import CoreML
import Foundation

public enum SpeakerEmbeddingError: LocalizedError, Equatable {
    case invalidStart
    case tooShort
    case silentAudio
    case audioDecodeFailed
    case invalidAudio
    case modelUnavailable
    case invalidModel
    case invalidEmbedding

    public var errorDescription: String? {
        switch self {
        case .invalidStart:
            return "The audio start time is invalid."
        case .tooShort:
            return "The audio does not contain three seconds at this start time."
        case .silentAudio:
            return "The selected audio is silent or too quiet."
        case .audioDecodeFailed:
            return "The audio could not be decoded."
        case .invalidAudio:
            return "The audio format is not supported for voice matching."
        case .modelUnavailable:
            return "The voice model resources are missing."
        case .invalidModel:
            return "The voice model could not be loaded."
        case .invalidEmbedding:
            return "The voice model returned an invalid embedding."
        }
    }
}

public actor SpeakerEmbedding {
    public static let modelID: String = "enzolabs/ecapa-tdnn-coreml@63b5971457021835bf1703dddf9ab34148646b4f+speechbrain-fbank-v1"

    static let sampleRate = 16_000
    static let clipSampleCount = 48_000
    static let frameLength = 400
    static let frameHop = 160
    static let frameCount = 301
    static let melBandCount = 80
    static let spectrumBinCount = frameLength / 2 + 1
    static let embeddingSize = 192
    static let melEnergyFloor = 1e-10
    static let melTopDB = 80.0

    private struct FrontendResources {
        let melFilterbank: [Float]
    }

    private let modelDirectoryURL: URL?
    private var loadedModel: MLModel?
    private var loadedFrontend: FrontendResources?

    public init(modelDirectoryURL: URL? = nil) {
        self.modelDirectoryURL = modelDirectoryURL
    }

    public func embedding(audioURL: URL, start: Double) async throws -> [Float] {
        try Task.checkCancellation()
        let samples = try Self.decodeClip(audioURL: audioURL, start: start)
        try Task.checkCancellation()

        let frontend = try frontendResources()
        let features = try Self.logMelFeatures(
            samples: samples,
            melFilterbank: frontend.melFilterbank
        )
        try Task.checkCancellation()

        let model = try coreMLModel()
        try Task.checkCancellation()
        let input = try Self.makeModelInput(features)
        try Task.checkCancellation()

        let output = try predict(model: model, input: input)
        try Task.checkCancellation()
        return try Self.normalizedEmbedding(from: output)
    }

    private func predict(model: MLModel, input: MLMultiArray) throws -> MLMultiArray {
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: ["mel_features": MLFeatureValue(multiArray: input)])
            let prediction = try model.prediction(from: provider, options: MLPredictionOptions())
            guard let output = prediction.featureValue(for: "embedding")?.multiArrayValue else {
                throw SpeakerEmbeddingError.invalidEmbedding
            }
            return output
        } catch let error as SpeakerEmbeddingError {
            throw error
        } catch {
            throw SpeakerEmbeddingError.invalidModel
        }
    }

    private func frontendResources() throws -> FrontendResources {
        if let loadedFrontend { return loadedFrontend }
        let directory = modelDirectoryURL ?? Bundle.main.bundleURL.appendingPathComponent("VoiceModel", isDirectory: true)
        do {
            let melFilterbank = try Self.readFloat32Resource(
                at: directory.appendingPathComponent("mel_filterbank.f32"),
                count: Self.melBandCount * Self.spectrumBinCount
            )
            guard melFilterbank.allSatisfy({ $0 >= 0 }) else {
                throw SpeakerEmbeddingError.invalidModel
            }
            let resources = FrontendResources(melFilterbank: melFilterbank)
            loadedFrontend = resources
            return resources
        } catch let error as SpeakerEmbeddingError {
            throw error
        } catch {
            throw SpeakerEmbeddingError.modelUnavailable
        }
    }

    private func coreMLModel() throws -> MLModel {
        if let loadedModel { return loadedModel }
        let directory = modelDirectoryURL ?? Bundle.main.bundleURL.appendingPathComponent("VoiceModel", isDirectory: true)
        let modelURL = directory.appendingPathComponent("speaker.mlmodelc", isDirectory: true)
        do {
            let model = try MLModel(contentsOf: modelURL)
            guard model.modelDescription.inputDescriptionsByName["mel_features"]?.multiArrayConstraint?.dataType == .float16 else {
                throw SpeakerEmbeddingError.invalidModel
            }
            loadedModel = model
            return model
        } catch let error as SpeakerEmbeddingError {
            throw error
        } catch {
            throw SpeakerEmbeddingError.invalidModel
        }
    }

    private static func decodeClip(audioURL: URL, start: Double) throws -> [Float] {
        guard audioURL.isFileURL else { throw SpeakerEmbeddingError.audioDecodeFailed }
        guard start.isFinite, start >= 0 else { throw SpeakerEmbeddingError.invalidStart }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SpeakerEmbeddingError.audioDecodeFailed
        }

        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        guard sourceRate.isFinite,
              sourceRate >= 8_000,
              sourceRate <= 384_000,
              sourceFormat.channelCount > 0,
              sourceFormat.channelCount <= 8 else {
            throw SpeakerEmbeddingError.invalidAudio
        }

        let duration = Double(file.length) / sourceRate
        guard duration.isFinite, start <= duration - 3.0 else {
            throw SpeakerEmbeddingError.tooShort
        }

        let sourceOffset = Int64((start * sourceRate).rounded(.toNearestOrAwayFromZero))
        let sourceFrameCount = Int64((3.0 * sourceRate).rounded(.toNearestOrAwayFromZero))
        guard sourceOffset >= 0,
              sourceFrameCount > 0,
              sourceFrameCount <= Int64(UInt32.max),
              sourceOffset <= file.length,
              sourceFrameCount <= file.length - sourceOffset else {
            throw SpeakerEmbeddingError.tooShort
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFrameCount)
        ) else {
            throw SpeakerEmbeddingError.audioDecodeFailed
        }
        guard let destinationChannels = sourceBuffer.floatChannelData else {
            throw SpeakerEmbeddingError.invalidAudio
        }
        let requestedSourceFrames = Int(sourceFrameCount)
        let chunkCapacity = AVAudioFrameCount(min(16_384, requestedSourceFrames))
        file.framePosition = sourceOffset
        var copiedFrames = 0
        while copiedFrames < requestedSourceFrames {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkCapacity) else {
                throw SpeakerEmbeddingError.audioDecodeFailed
            }
            do {
                try file.read(into: chunk, frameCount: min(chunkCapacity, AVAudioFrameCount(requestedSourceFrames - copiedFrames)))
            } catch {
                throw SpeakerEmbeddingError.audioDecodeFailed
            }
            let framesRead = Int(chunk.frameLength)
            guard framesRead > 0, let sourceChannels = chunk.floatChannelData else {
                throw SpeakerEmbeddingError.tooShort
            }
            for channelIndex in 0..<Int(sourceFormat.channelCount) {
                destinationChannels[channelIndex].advanced(by: copiedFrames).update(
                    from: sourceChannels[channelIndex],
                    count: framesRead
                )
            }
            copiedFrames += framesRead
        }
        sourceBuffer.frameLength = AVAudioFrameCount(requestedSourceFrames)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(clipSampleCount + 1_024)
              ) else {
            throw SpeakerEmbeddingError.invalidAudio
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error else { throw SpeakerEmbeddingError.audioDecodeFailed }
        guard outputBuffer.frameLength >= AVAudioFrameCount(clipSampleCount),
              let channel = outputBuffer.floatChannelData?[0] else {
            throw SpeakerEmbeddingError.audioDecodeFailed
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: clipSampleCount))
        guard samples.allSatisfy(\.isFinite) else { throw SpeakerEmbeddingError.invalidAudio }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(clipSampleCount)
        guard meanSquare.isFinite, meanSquare.squareRoot() > 1e-5 else {
            throw SpeakerEmbeddingError.silentAudio
        }
        return samples
    }

    static func logMelFeatures(samples: [Float], melFilterbank: [Float]) throws -> [Float] {
        guard samples.count == clipSampleCount,
              melFilterbank.count == melBandCount * spectrumBinCount,
              melFilterbank.allSatisfy({ $0.isFinite && $0 >= 0 }),
              samples.allSatisfy(\.isFinite) else {
            throw SpeakerEmbeddingError.invalidAudio
        }
        // Match the model's SpeechBrain Fbank training frontend.
        let window = hammingWindow()
        guard let setup = vDSP_DFT_CreateSetup(nil, vDSP_Length(frameLength)) else {
            throw SpeakerEmbeddingError.invalidModel
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        var powers = [Float](repeating: 0, count: spectrumBinCount * frameCount)
        for frameIndex in 0..<frameCount {
            var realInput = [Float](repeating: 0, count: frameLength)
            let imaginaryInput = [Float](repeating: 0, count: frameLength)
            var realOutput = [Float](repeating: 0, count: frameLength)
            var imaginaryOutput = [Float](repeating: 0, count: frameLength)
            let center = frameIndex * frameHop
            for sampleIndex in 0..<frameLength {
                realInput[sampleIndex] = centeredSample(
                    samples: samples,
                    center: center,
                    offset: sampleIndex
                ) * window[sampleIndex]
            }

            realInput.withUnsafeBufferPointer { realIn in
                imaginaryInput.withUnsafeBufferPointer { imaginaryIn in
                    realOutput.withUnsafeMutableBufferPointer { realOut in
                        imaginaryOutput.withUnsafeMutableBufferPointer { imaginaryOut in
                            vDSP_DFT_zop(
                                setup,
                                realIn.baseAddress!,
                                imaginaryIn.baseAddress!,
                                1,
                                realOut.baseAddress!,
                                imaginaryOut.baseAddress!,
                                1,
                                vDSP_DFT_Direction.FORWARD
                            )
                        }
                    }
                }
            }
            for bin in 0..<spectrumBinCount {
                powers[bin * frameCount + frameIndex] = realOutput[bin] * realOutput[bin] + imaginaryOutput[bin] * imaginaryOutput[bin]
            }
        }

        var melEnergies = [Float](repeating: 0, count: melBandCount * frameCount)
        melFilterbank.withUnsafeBufferPointer { filters in
            powers.withUnsafeBufferPointer { spectrum in
                melEnergies.withUnsafeMutableBufferPointer { mel in
                    vDSP_mmul(
                        filters.baseAddress!,
                        1,
                        spectrum.baseAddress!,
                        1,
                        mel.baseAddress!,
                        1,
                        vDSP_Length(melBandCount),
                        vDSP_Length(frameCount),
                        vDSP_Length(spectrumBinCount)
                    )
                }
            }
        }

        return try normalizeMelEnergies(melEnergies)
    }

    static func hammingWindow() -> [Float] {
        (0..<frameLength).map { index in
            Float(0.54 - 0.46 * cos(2 * Double.pi * Double(index) / Double(frameLength)))
        }
    }

    static func centeredSample(samples: [Float], center: Int, offset: Int) -> Float {
        let sourceIndex = center + offset - frameLength / 2
        return sourceIndex >= 0 && sourceIndex < samples.count ? samples[sourceIndex] : 0
    }

    static func normalizeMelEnergies(_ melEnergies: [Float]) throws -> [Float] {
        guard melEnergies.count == melBandCount * frameCount,
              melEnergies.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SpeakerEmbeddingError.invalidAudio
        }

        var decibels = melEnergies.map { energy in
            10 * Foundation.log10(max(Double(energy), melEnergyFloor))
        }
        guard let maximum = decibels.max() else { throw SpeakerEmbeddingError.invalidAudio }
        let floor = maximum - melTopDB
        decibels = decibels.map { max($0, floor) }

        var features = [Float](repeating: 0, count: decibels.count)
        for band in 0..<melBandCount {
            let bandStart = band * frameCount
            var mean = 0.0
            for frame in 0..<frameCount {
                mean += decibels[bandStart + frame]
            }
            mean /= Double(frameCount)
            for frame in 0..<frameCount {
                features[bandStart + frame] = Float(decibels[bandStart + frame] - mean)
            }
        }
        guard features.allSatisfy(\.isFinite) else { throw SpeakerEmbeddingError.invalidAudio }
        return features
    }

    static func powerSpectrum(frame: [Float], window: [Float]) throws -> [Float] {
        guard frame.count == frameLength, window.count == frameLength,
              frame.allSatisfy(\.isFinite), window.allSatisfy(\.isFinite) else {
            throw SpeakerEmbeddingError.invalidAudio
        }
        guard let setup = vDSP_DFT_CreateSetup(nil, vDSP_Length(frameLength)) else {
            throw SpeakerEmbeddingError.invalidModel
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        let realInput = zip(frame, window).map { $0 * $1 }
        let imaginaryInput = [Float](repeating: 0, count: frameLength)
        var realOutput = [Float](repeating: 0, count: frameLength)
        var imaginaryOutput = [Float](repeating: 0, count: frameLength)
        realInput.withUnsafeBufferPointer { realIn in
            imaginaryInput.withUnsafeBufferPointer { imaginaryIn in
                realOutput.withUnsafeMutableBufferPointer { realOut in
                    imaginaryOutput.withUnsafeMutableBufferPointer { imaginaryOut in
                        vDSP_DFT_zop(
                            setup,
                            realIn.baseAddress!,
                            imaginaryIn.baseAddress!,
                            1,
                            realOut.baseAddress!,
                            imaginaryOut.baseAddress!,
                            1,
                            vDSP_DFT_Direction.FORWARD
                        )
                    }
                }
            }
        }
        return (0..<spectrumBinCount).map { realOutput[$0] * realOutput[$0] + imaginaryOutput[$0] * imaginaryOutput[$0] }
    }

    private static func readFloat32Resource(at url: URL, count: Int) throws -> [Float] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SpeakerEmbeddingError.modelUnavailable
        }
        guard data.count == count * MemoryLayout<Float>.size else {
            throw SpeakerEmbeddingError.invalidModel
        }
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let offset = index * 4
            let bits = UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
            values[index] = Float(bitPattern: bits)
        }
        guard values.allSatisfy(\.isFinite) else { throw SpeakerEmbeddingError.invalidModel }
        return values
    }

    private static func makeModelInput(_ features: [Float]) throws -> MLMultiArray {
        guard features.count == melBandCount * frameCount else { throw SpeakerEmbeddingError.invalidModel }
        let input: MLMultiArray
        do {
            input = try MLMultiArray(
                shape: [1, NSNumber(value: melBandCount), NSNumber(value: frameCount)],
                dataType: .float16
            )
        } catch {
            throw SpeakerEmbeddingError.invalidModel
        }
        let strides = input.strides.map(\.intValue)
        guard strides.count == 3 else { throw SpeakerEmbeddingError.invalidModel }
        let pointer = input.dataPointer.bindMemory(to: Float16.self, capacity: melBandCount * frameCount)
        for band in 0..<melBandCount {
            for frame in 0..<frameCount {
                let destination = band * strides[1] + frame * strides[2]
                pointer[destination] = Float16(features[band * frameCount + frame])
            }
        }
        return input
    }

    private static func normalizedEmbedding(from output: MLMultiArray) throws -> [Float] {
        guard output.dataType == .float16,
              output.shape.map(\.intValue) == [1, embeddingSize] else {
            throw SpeakerEmbeddingError.invalidEmbedding
        }
        let strides = output.strides.map(\.intValue)
        guard strides.count == 2 else { throw SpeakerEmbeddingError.invalidEmbedding }
        let pointer = output.dataPointer.bindMemory(to: Float16.self, capacity: embeddingSize)
        let values = (0..<embeddingSize).map { Float(pointer[$0 * strides[1]]) }
        guard values.allSatisfy(\.isFinite) else { throw SpeakerEmbeddingError.invalidEmbedding }
        let normSquared = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard normSquared.isFinite, normSquared > 1e-20 else { throw SpeakerEmbeddingError.invalidEmbedding }
        let norm = normSquared.squareRoot()
        return values.map { Float(Double($0) / norm) }
    }
}
