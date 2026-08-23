import Foundation

/// One sherpa-onnx recognizer. The C bridge keeps the Swift side independent
/// of the large generated API surface and exposes only the offline ASR calls
/// VocaPhone needs.
final class SherpaRecognizer: @unchecked Sendable {
    private let native: UnsafeMutableRawPointer
    /// Whether this recognizer was built to translate, which changes how a
    /// recording too long for one decode is put back together. See `transcribe`.
    private let translating: Bool

    private init(native: UnsafeMutableRawPointer, translating: Bool = false) {
        self.native = native
        self.translating = translating
    }

    deinit {
        VocaPhoneSherpaDestroy(native)
    }

    static func create(
        model: LocalModelDescriptor,
        directory: URL,
        language: String,
        threads: Int,
        quality: TranscriptionQuality,
        translateTo: String = ""
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
            // Canary's config has no detection mode, so "auto" has to become a
            // real code — English is the safest guess and the one upstream's
            // own examples use.
            languageHint = language == "auto" ? "en" : language
        case .senseVoice:
            languageHint = language == "auto" ? "" : language
        default:
            languageHint = ""
        }
        // Only Canary has a target at all; the bridge falls back to the source
        // when this is empty, which is what transcription is.
        let targetHint = family == .canary ? translateTo : ""

        // Never `quality.sherpaDecodingMethod` on its own: a family that does
        // not support beam search answers it by killing the process.
        let decodingMethod = family.decodingMethod(for: quality)
        let native: UnsafeMutableRawPointer? = models[0].withCString { model1 in
            models[1].withCString { model2 in
                models[2].withCString { model3 in
                    models[3].withCString { model4 in
                        tokens.withCString { tokensPointer in
                            languageHint.withCString { languagePointer in
                                targetHint.withCString { targetPointer in
                                    decodingMethod.withCString { decodingMethodPointer in
                                        VocaPhoneSherpaCreate(
                                            Int32(family.bridgeValue),
                                            model1, model2, model3, model4,
                                            tokensPointer, languagePointer, targetPointer,
                                            Int32(threads), decodingMethodPointer,
                                            quality.sherpaMaxActivePaths
                                        )
                                    }
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
        // Only the families that can honour a target are translating, whatever
        // the caller asked for.
        return SherpaRecognizer(
            native: native,
            translating: family.acceptsLanguage && !translateTo.isEmpty
        )
    }

    /// Decodes the whole recording, in windows if it is longer than one decode
    /// should be.
    ///
    /// Those windows are where translation and transcription part company. A
    /// transcriber returns the same words for the same audio, so a window that
    /// retains a little of the one before it can have the repeat matched and
    /// removed. A translator does not: the retained audio is translated again
    /// inside a different sentence, comes back in different words, and nothing
    /// can pair the two. Worse, a merger still looking for a repeat can only
    /// match a phrase the speaker genuinely said twice — and delete it.
    ///
    /// A boundary the silence search found is already cut clean here, so only
    /// a guessed one carries audio across, and while translating that seam is
    /// left as it decoded rather than merged by matching words.
    func transcribe(_ samples: [Float]) -> SherpaTranscript {
        let transcript = SherpaLongAudio.chunks(samples)
            .reduce(into: SherpaTranscript.empty) { transcript, chunk in
                let bounded = Array(samples[chunk.start..<chunk.endExclusive])
                let decoded = SherpaEmptyChunkRecovery.decode(samples: bounded, decodeOnce: decode)
                transcript = transcript.appending(
                    decoded, deduplicateOverlap: chunk.overlapsPrevious && !translating
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
    static func decode(
        samples: [Float], decodeOnce: ([Float]) -> SherpaTranscript
    ) -> SherpaTranscript {
        guard !SherpaLongAudio.isEffectivelySilent(samples) else { return .empty }
        let attempt = decodeOnce(samples)
        let first = SherpaTranscript(
            text: attempt.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: attempt.language
        )
        guard first.text.isEmpty,
              samples.count > SherpaLongAudio.minimumSuspectChunkSamples
        else { return first }
        let midpoint = samples.count / 2
        return decodeOnce(Array(samples[..<midpoint]))
            .appending(decodeOnce(Array(samples[midpoint...])), deduplicateOverlap: false)
    }
}

extension SherpaIncrementalSession {
    /// The session lives in the shared target and takes a decode closure so it
    /// can be tested without the native engine; this is the one call site that
    /// has a real recognizer to give it.
    convenience init(chunks: AsyncStream<Data>, recognizer: SherpaRecognizer) {
        self.init(chunks: chunks) { recognizer.transcribeChunk($0) }
    }
}
