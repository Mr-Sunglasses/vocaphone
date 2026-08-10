import Foundation

/// One sherpa-onnx recognizer. The C bridge keeps the Swift side independent
/// of the large generated API surface and exposes only the offline ASR calls
/// VocaPhone needs.
final class SherpaRecognizer: @unchecked Sendable {
    private let native: UnsafeMutableRawPointer

    private init(native: UnsafeMutableRawPointer) {
        self.native = native
    }

    deinit {
        VocaPhoneSherpaDestroy(native)
    }

    static func create(
        model: LocalModelDescriptor,
        directory: URL,
        language: String,
        threads: Int
    ) throws -> SherpaRecognizer {
        guard let family = model.sherpaFamily else {
            throw LocalModelManagerError.unsupportedModel(model.id)
        }

        func path(_ name: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LocalModelManagerError.integrityFileMissing(name)
            }
            return url.path
        }

        let tokens = try path("tokens.txt")
        let models: [String]
        switch family {
        case .nemoTransducer:
            models = try [path("encoder.int8.onnx"), path("decoder.int8.onnx"), path("joiner.int8.onnx"), ""]
        case .moonshine:
            models = try [
                path("preprocess.onnx"), path("encode.int8.onnx"),
                path("uncached_decode.int8.onnx"), path("cached_decode.int8.onnx")
            ]
        case .canary:
            models = try [path("encoder.int8.onnx"), path("decoder.int8.onnx"), "", ""]
        case .senseVoice, .dolphinCtc, .paraformer:
            models = try [path("model.int8.onnx"), "", "", ""]
        case .nemoCtc:
            let name = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("model.onnx").path
            ) ? "model.onnx" : "model.int8.onnx"
            models = try [path(name), "", "", ""]
        }

        let languageHint: String
        switch family {
        case .canary:
            languageHint = language == "auto" ? "en" : language
        case .senseVoice:
            languageHint = language == "auto" ? "" : language
        default:
            languageHint = ""
        }

        let native: UnsafeMutableRawPointer? = models[0].withCString { model1 in
            models[1].withCString { model2 in
                models[2].withCString { model3 in
                    models[3].withCString { model4 in
                        tokens.withCString { tokensPointer in
                            languageHint.withCString { languagePointer in
                                VocaPhoneSherpaCreate(
                                    Int32(family.bridgeValue), model1, model2, model3, model4,
                                    tokensPointer, languagePointer, Int32(threads)
                                )
                            }
                        }
                    }
                }
            }
        }
        guard let native else {
            throw LocalModelManagerError.engineLoadFailed(model.id)
        }
        return SherpaRecognizer(native: native)
    }

    func transcribe(_ samples: [Float]) -> String {
        let transcript = SherpaLongAudio.chunks(samples).reduce(into: "") { transcript, chunk in
            let bounded = Array(samples[chunk.start..<chunk.endExclusive])
            let text = SherpaEmptyChunkRecovery.decode(samples: bounded, decodeOnce: decode)
            transcript = SherpaTranscriptMerger.append(
                existing: transcript,
                next: text,
                deduplicateOverlap: chunk.overlapsPrevious
            )
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeChunk(_ samples: [Float]) -> String {
        SherpaEmptyChunkRecovery.decode(samples: samples, decodeOnce: decode)
    }

    private func decode(_ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "" }
        var output = [CChar](repeating: 0, count: 131_072)
        let result = samples.withUnsafeBufferPointer { sampleBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                VocaPhoneSherpaDecode(
                    native,
                    sampleBuffer.baseAddress,
                    Int32(samples.count),
                    outputBuffer.baseAddress,
                    Int32(outputBuffer.count)
                )
            }
        }
        guard result >= 0 else { return "" }
        let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension SherpaFamily {
    var bridgeValue: Int {
        switch self {
        case .nemoTransducer: 0
        case .senseVoice: 1
        case .moonshine: 2
        case .dolphinCtc: 3
        case .canary: 4
        case .nemoCtc: 5
        case .paraformer: 6
        }
    }
}

private enum SherpaEmptyChunkRecovery {
    private static let minimumRetrySamples = 6 * SherpaLongAudio.sampleRate

    static func decode(samples: [Float], decodeOnce: ([Float]) -> String) -> String {
        guard !SherpaLongAudio.isEffectivelySilent(samples) else { return "" }
        let first = decodeOnce(samples).trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.isEmpty, samples.count > minimumRetrySamples else { return first }
        let midpoint = samples.count / 2
        return SherpaTranscriptMerger.append(
            existing: decodeOnce(Array(samples[..<midpoint])),
            next: decodeOnce(Array(samples[midpoint...])),
            deduplicateOverlap: false
        )
    }
}

/// Consumes captured PCM while the microphone is still running. The WAV file
/// remains authoritative, but Sherpa's expensive offline work is spread over
/// the recording instead of making the user wait for the whole file at finish.
final class SherpaIncrementalSession: @unchecked Sendable {
    private let task: Task<String, Never>

    init(chunks: AsyncStream<Data>, recognizer: SherpaRecognizer) {
        task = Task.detached(priority: .userInitiated) {
            await Self.transcribe(chunks: chunks, recognizer: recognizer)
        }
    }

    func finish() async -> String { await task.value }

    func cancel() { task.cancel() }

    private static func transcribe(
        chunks: AsyncStream<Data>,
        recognizer: SherpaRecognizer
    ) async -> String {
        var samples: [Float] = []
        samples.reserveCapacity(
            SherpaLongAudio.streamingWindowSeconds * SherpaLongAudio.sampleRate
        )
        var transcript = ""
        var overlapsPrevious = false

        for await data in chunks {
            guard !Task.isCancelled else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            samples.append(contentsOf: Self.floatSamples(in: data))

            while let split = SherpaLongAudio.nextStreamingSplit(samples) {
                let bounded = Array(samples[..<split.endExclusive])
                let text = recognizer.transcribeChunk(bounded)
                transcript = SherpaTranscriptMerger.append(
                    existing: transcript,
                    next: text,
                    deduplicateOverlap: overlapsPrevious
                )
                samples.removeFirst(split.nextStart)
                overlapsPrevious = split.nextStart < split.endExclusive
            }
        }

        if !samples.isEmpty {
            transcript = SherpaTranscriptMerger.append(
                existing: transcript,
                next: recognizer.transcribeChunk(samples),
                deduplicateOverlap: overlapsPrevious
            )
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func floatSamples(in data: Data) -> [Float] {
        guard data.count >= MemoryLayout<Float>.stride else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float.self)
            return Array(values)
        }
    }
}
