import Foundation

/// One sherpa-onnx recognizer. The C bridge keeps the Swift side independent
/// of the large generated API surface and exposes only the offline ASR calls
/// VocaPhone needs.
final class SherpaRecognizer: @unchecked Sendable {
    private let native: UnsafeMutableRawPointer
    /// sherpa-onnx recognizers are mutable native objects. Incremental decoding
    /// runs off the main actor while a retry or settings preparation can also
    /// reach this instance, so one recognizer must never decode two streams at
    /// once.
    private let decodeLock = NSLock()
    /// Whether this recognizer was built to translate, which changes how a
    /// recording too long for one decode is put back together. See `transcribe`.
    private let translating: Bool
    /// The feature noise this family needs, applied to the waveform because the
    /// pinned runtime has no `dither` field to ask for it. See
    /// `SherpaFeatureDither` and `SherpaFamily.featureDither`.
    private let featureDither: Float

    private init(
        native: UnsafeMutableRawPointer,
        translating: Bool = false,
        featureDither: Float = 0
    ) {
        self.native = native
        self.translating = translating
        self.featureDither = featureDither
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

        /// The quantized file where the model ships one, the plain file where
        /// it does not. Upstream quantizes per graph rather than per model:
        /// GigaAM's transducer ships an int8 encoder beside a full-precision
        /// decoder and joiner, because those two are small enough that
        /// quantizing them costs accuracy for nothing.
        func quantizedOrPlain(_ stem: String) throws -> String {
            let int8 = directory.appendingPathComponent("\(stem).int8.onnx")
            return FileManager.default.fileExists(atPath: int8.path)
                ? int8.path
                : try path("\(stem).onnx")
        }

        let tokens = try path("tokens.txt")
        let models: [String]
        switch family {
        case .nemoTransducer:
            models = try [
                quantizedOrPlain("encoder"), quantizedOrPlain("decoder"),
                quantizedOrPlain("joiner"), ""
            ]
        case .moonshine:
            models = try [
                path("preprocess.onnx"), path("encode.int8.onnx"),
                path("uncached_decode.int8.onnx"), path("cached_decode.int8.onnx")
            ]
        case .moonshineV2:
            models = try [path("encoder_model.ort"), path("decoder_model_merged.ort"), "", ""]
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
            translating: family.acceptsLanguage && !translateTo.isEmpty,
            featureDither: family.featureDither
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
    func transcribe(_ samples: [Float]) -> SherpaDecodeOutcome {
        var transcript = SherpaTranscript.empty
        var previousEnd = 0
        var loudestSoFar = 0.0
        for chunk in SherpaLongAudio.chunks(samples) {
            let bounded = Array(samples[chunk.start..<chunk.endExclusive])
            // Whether a short empty answer is ordinary is a question about the
            // audio this window did not inherit from the one before it. A final
            // window that is only the retained overlap has nothing new in it,
            // and an empty answer there is correct. A final window carrying a
            // whole further sentence is the reported failure, and it is that
            // whether or not an earlier window already produced text — judging
            // it by the transcript so far is what let a closing sentence
            // disappear behind a successful opening one.
            let newRegion = SherpaLongAudio.newRegion(
                of: samples, chunk: chunk, previousEnd: previousEnd
            )
            let newRegionLevel = SherpaLongAudio.loudestFrame(newRegion)
            let carriesNewSpeech = SherpaLongAudio.carriesRecoverableSpeech(
                newRegion: newRegion,
                inheritsAudio: chunk.overlapsPrevious,
                loudestFrame: newRegionLevel,
                loudestFrameSoFar: loudestSoFar
            )
            let outcome = SherpaEmptyChunkRecovery.decode(
                samples: bounded,
                decodeOnce: decode,
                deduplicateOverlap: !translating,
                recoverAudibleShortInput: carriesNewSpeech
            )
            guard case let .decoded(decoded) = outcome else { return outcome }
            loudestSoFar = max(loudestSoFar, newRegionLevel)
            previousEnd = chunk.endExclusive
            transcript = transcript.appending(
                decoded, deduplicateOverlap: chunk.overlapsPrevious && !translating
            )
        }
        return .decoded(
            SherpaTranscript(
                text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: transcript.language
            )
        )
    }

    func transcribeChunk(_ samples: [Float]) -> SherpaDecodeOutcome {
        SherpaEmptyChunkRecovery.decode(
            samples: samples, decodeOnce: decode, deduplicateOverlap: !translating
        )
    }

    private func decode(_ samples: [Float]) -> SherpaDecodeOutcome {
        guard !samples.isEmpty else { return .failed(.invalidArgument) }
        let samples = SherpaFeatureDither.applied(to: samples, dither: featureDither)
        decodeLock.lock()
        defer { decodeLock.unlock() }
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
        // A negative status is the engine failing to answer, and it must never
        // reach the caller looking like a model that answered nothing.
        guard result >= 0 else { return .failed(.forStatus(result)) }
        return .decoded(
            SherpaTranscript(
                text: Self.string(from: output),
                language: SherpaTranscript.languageCode(Self.string(from: languageOutput))
            )
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
        case .moonshineV2: 7
        }
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
