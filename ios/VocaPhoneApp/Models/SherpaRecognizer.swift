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
        threads: Int,
        quality: TranscriptionQuality
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

        // Never `quality.sherpaDecodingMethod` on its own: a family that does
        // not support beam search answers it by killing the process.
        let decodingMethod = family.decodingMethod(for: quality)
        let native: UnsafeMutableRawPointer? = models[0].withCString { model1 in
            models[1].withCString { model2 in
                models[2].withCString { model3 in
                    models[3].withCString { model4 in
                        tokens.withCString { tokensPointer in
                            languageHint.withCString { languagePointer in
                                decodingMethod.withCString { decodingMethodPointer in
                                    VocaPhoneSherpaCreate(
                                        Int32(family.bridgeValue), model1, model2, model3, model4,
                                        tokensPointer, languagePointer, Int32(threads),
                                        decodingMethodPointer, quality.sherpaMaxActivePaths
                                    )
                                }
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

    func transcribe(_ samples: [Float]) -> SherpaTranscript {
        let transcript = SherpaLongAudio.chunks(samples)
            .reduce(into: SherpaTranscript.empty) { transcript, chunk in
                let bounded = Array(samples[chunk.start..<chunk.endExclusive])
                let decoded = SherpaEmptyChunkRecovery.decode(samples: bounded, decodeOnce: decode)
                transcript = transcript.appending(
                    decoded, deduplicateOverlap: chunk.overlapsPrevious
                )
            }
        return SherpaTranscript(
            text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: transcript.language
        )
    }

    func transcribeChunk(_ samples: [Float]) -> SherpaTranscript {
        SherpaEmptyChunkRecovery.decode(samples: samples, decodeOnce: decode)
    }

    private func decode(_ samples: [Float]) -> SherpaTranscript {
        guard !samples.isEmpty else { return .empty }
        var output = [CChar](repeating: 0, count: 131_072)
        // Only ever holds a short tag such as "<|en|>".
        var languageOutput = [CChar](repeating: 0, count: 32)
        let result = samples.withUnsafeBufferPointer { sampleBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                languageOutput.withUnsafeMutableBufferPointer { languageBuffer in
                    VocaPhoneSherpaDecode(
                        native,
                        sampleBuffer.baseAddress,
                        Int32(samples.count),
                        outputBuffer.baseAddress,
                        Int32(outputBuffer.count),
                        languageBuffer.baseAddress,
                        Int32(languageBuffer.count)
                    )
                }
            }
        }
        guard result >= 0 else { return .empty }
        return SherpaTranscript(
            text: Self.string(from: output),
            language: SherpaTranscript.languageCode(Self.string(from: languageOutput))
        )
    }

    private static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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

    static func decode(
        samples: [Float], decodeOnce: ([Float]) -> SherpaTranscript
    ) -> SherpaTranscript {
        guard !SherpaLongAudio.isEffectivelySilent(samples) else { return .empty }
        let attempt = decodeOnce(samples)
        let first = SherpaTranscript(
            text: attempt.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: attempt.language
        )
        guard first.text.isEmpty, samples.count > minimumRetrySamples else { return first }
        let midpoint = samples.count / 2
        return decodeOnce(Array(samples[..<midpoint]))
            .appending(decodeOnce(Array(samples[midpoint...])), deduplicateOverlap: false)
    }
}

/// Consumes captured PCM while the microphone is still running. The WAV file
/// remains authoritative, but Sherpa's expensive offline work is spread over
/// the recording instead of making the user wait for the whole file at finish.
final class SherpaIncrementalSession: @unchecked Sendable {
    private let task: Task<SherpaTranscript, Never>

    init(chunks: AsyncStream<Data>, recognizer: SherpaRecognizer) {
        task = Task.detached(priority: .userInitiated) {
            await Self.transcribe(chunks: chunks, recognizer: recognizer)
        }
    }

    func finish() async -> SherpaTranscript { await task.value }

    func cancel() { task.cancel() }

    private static func transcribe(
        chunks: AsyncStream<Data>,
        recognizer: SherpaRecognizer
    ) async -> SherpaTranscript {
        var samples: [Float] = []
        samples.reserveCapacity(
            SherpaLongAudio.streamingWindowSeconds * SherpaLongAudio.sampleRate
        )
        var transcript = SherpaTranscript.empty
        var overlapsPrevious = false

        for await data in chunks {
            guard !Task.isCancelled else { return Self.trimmed(transcript) }
            samples.append(contentsOf: Self.floatSamples(in: data))

            while let split = SherpaLongAudio.nextStreamingSplit(samples) {
                let bounded = Array(samples[..<split.endExclusive])
                transcript = transcript.appending(
                    recognizer.transcribeChunk(bounded),
                    deduplicateOverlap: overlapsPrevious
                )
                samples.removeFirst(split.nextStart)
                overlapsPrevious = split.nextStart < split.endExclusive
            }
        }

        if !samples.isEmpty {
            transcript = transcript.appending(
                recognizer.transcribeChunk(samples),
                deduplicateOverlap: overlapsPrevious
            )
        }
        return Self.trimmed(transcript)
    }

    private static func trimmed(_ transcript: SherpaTranscript) -> SherpaTranscript {
        SherpaTranscript(
            text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: transcript.language
        )
    }

    private static func floatSamples(in data: Data) -> [Float] {
        guard data.count >= MemoryLayout<Float>.stride else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float.self)
            return Array(values)
        }
    }
}
