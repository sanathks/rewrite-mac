// Trimmed sherpa-onnx Swift wrapper -- offline recognition only
// Based on https://github.com/k2-fsa/sherpa-onnx swift-api-examples/SherpaOnnx.swift

import Foundation
import CSherpaOnnx

// MARK: - Helpers

public func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
    let cs = (s as NSString).utf8String
    return UnsafePointer<Int8>(cs)
}

public func sherpaOnnxFeatureConfig(
    sampleRate: Int = 16000,
    featureDim: Int = 80
) -> SherpaOnnxFeatureConfig {
    return SherpaOnnxFeatureConfig(
        sample_rate: Int32(sampleRate),
        feature_dim: Int32(featureDim)
    )
}

public func sherpaOnnxHomophoneReplacerConfig(
    dictDir: String = "",
    lexicon: String = "",
    ruleFsts: String = ""
) -> SherpaOnnxHomophoneReplacerConfig {
    return SherpaOnnxHomophoneReplacerConfig(
        dict_dir: toCPointer(dictDir),
        lexicon: toCPointer(lexicon),
        rule_fsts: toCPointer(ruleFsts)
    )
}

// MARK: - Offline Model Configs

public func sherpaOnnxOfflineTransducerModelConfig(
    encoder: String = "",
    decoder: String = "",
    joiner: String = ""
) -> SherpaOnnxOfflineTransducerModelConfig {
    return SherpaOnnxOfflineTransducerModelConfig(
        encoder: toCPointer(encoder),
        decoder: toCPointer(decoder),
        joiner: toCPointer(joiner)
    )
}

public func sherpaOnnxOfflineParaformerModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineParaformerModelConfig {
    return SherpaOnnxOfflineParaformerModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineNemoEncDecCtcModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineNemoEncDecCtcModelConfig {
    return SherpaOnnxOfflineNemoEncDecCtcModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineWhisperModelConfig(
    encoder: String = "",
    decoder: String = "",
    language: String = "",
    task: String = "",
    tailPaddings: Int = -1,
    enableTokenTimestamps: Bool = false,
    enableSegmentTimestamps: Bool = false
) -> SherpaOnnxOfflineWhisperModelConfig {
    return SherpaOnnxOfflineWhisperModelConfig(
        encoder: toCPointer(encoder),
        decoder: toCPointer(decoder),
        language: toCPointer(language),
        task: toCPointer(task),
        tail_paddings: Int32(tailPaddings),
        enable_token_timestamps: enableTokenTimestamps ? 1 : 0,
        enable_segment_timestamps: enableSegmentTimestamps ? 1 : 0
    )
}

public func sherpaOnnxOfflineTdnnModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineTdnnModelConfig {
    return SherpaOnnxOfflineTdnnModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineSenseVoiceModelConfig(
    model: String = "",
    language: String = "",
    useInverseTextNormalization: Bool = false
) -> SherpaOnnxOfflineSenseVoiceModelConfig {
    return SherpaOnnxOfflineSenseVoiceModelConfig(
        model: toCPointer(model),
        language: toCPointer(language),
        use_itn: useInverseTextNormalization ? 1 : 0
    )
}

public func sherpaOnnxOfflineMoonshineModelConfig(
    preprocessor: String = "",
    encoder: String = "",
    uncachedDecoder: String = "",
    cachedDecoder: String = "",
    mergedDecoder: String = ""
) -> SherpaOnnxOfflineMoonshineModelConfig {
    return SherpaOnnxOfflineMoonshineModelConfig(
        preprocessor: toCPointer(preprocessor),
        encoder: toCPointer(encoder),
        uncached_decoder: toCPointer(uncachedDecoder),
        cached_decoder: toCPointer(cachedDecoder),
        merged_decoder: toCPointer(mergedDecoder)
    )
}

public func sherpaOnnxOfflineFireRedAsrModelConfig(
    encoder: String = "",
    decoder: String = ""
) -> SherpaOnnxOfflineFireRedAsrModelConfig {
    return SherpaOnnxOfflineFireRedAsrModelConfig(
        encoder: toCPointer(encoder),
        decoder: toCPointer(decoder)
    )
}

public func sherpaOnnxOfflineCanaryModelConfig(
    encoder: String = "",
    decoder: String = "",
    srcLang: String = "en",
    tgtLang: String = "en",
    usePnc: Bool = true
) -> SherpaOnnxOfflineCanaryModelConfig {
    return SherpaOnnxOfflineCanaryModelConfig(
        encoder: toCPointer(encoder),
        decoder: toCPointer(decoder),
        src_lang: toCPointer(srcLang),
        tgt_lang: toCPointer(tgtLang),
        use_pnc: usePnc ? 1 : 0
    )
}

public func sherpaOnnxOfflineDolphinModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineDolphinModelConfig {
    return SherpaOnnxOfflineDolphinModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineZipformerCtcModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineZipformerCtcModelConfig {
    return SherpaOnnxOfflineZipformerCtcModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineWenetCtcModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineWenetCtcModelConfig {
    return SherpaOnnxOfflineWenetCtcModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
    return SherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineMedAsrCtcModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineMedAsrCtcModelConfig {
    return SherpaOnnxOfflineMedAsrCtcModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineFireRedAsrCtcModelConfig(
    model: String = ""
) -> SherpaOnnxOfflineFireRedAsrCtcModelConfig {
    return SherpaOnnxOfflineFireRedAsrCtcModelConfig(
        model: toCPointer(model)
    )
}

public func sherpaOnnxOfflineFunASRNanoModelConfig(
    encoderAdaptor: String = "",
    llm: String = "",
    embedding: String = "",
    tokenizer: String = "",
    systemPrompt: String = "You are a helpful assistant.",
    userPrompt: String = "",
    maxNewTokens: Int = 512,
    temperature: Float = 1e-6,
    topP: Float = 0.8,
    seed: Int = 42,
    language: String = "",
    itn: Bool = true,
    hotwords: String = ""
) -> SherpaOnnxOfflineFunASRNanoModelConfig {
    return SherpaOnnxOfflineFunASRNanoModelConfig(
        encoder_adaptor: toCPointer(encoderAdaptor),
        llm: toCPointer(llm),
        embedding: toCPointer(embedding),
        tokenizer: toCPointer(tokenizer),
        system_prompt: toCPointer(systemPrompt),
        user_prompt: toCPointer(userPrompt),
        max_new_tokens: Int32(maxNewTokens),
        temperature: temperature,
        top_p: topP,
        seed: Int32(seed),
        language: toCPointer(language),
        itn: itn ? 1 : 0,
        hotwords: toCPointer(hotwords)
    )
}

// MARK: - Offline LM Config

public func sherpaOnnxOfflineLMConfig(
    model: String = "",
    scale: Float = 1.0
) -> SherpaOnnxOfflineLMConfig {
    return SherpaOnnxOfflineLMConfig(
        model: toCPointer(model),
        scale: scale
    )
}

// MARK: - Offline Model Config (top-level)

public func sherpaOnnxOfflineModelConfig(
    tokens: String,
    transducer: SherpaOnnxOfflineTransducerModelConfig = sherpaOnnxOfflineTransducerModelConfig(),
    paraformer: SherpaOnnxOfflineParaformerModelConfig = sherpaOnnxOfflineParaformerModelConfig(),
    nemoCtc: SherpaOnnxOfflineNemoEncDecCtcModelConfig = sherpaOnnxOfflineNemoEncDecCtcModelConfig(),
    whisper: SherpaOnnxOfflineWhisperModelConfig = sherpaOnnxOfflineWhisperModelConfig(),
    tdnn: SherpaOnnxOfflineTdnnModelConfig = sherpaOnnxOfflineTdnnModelConfig(),
    numThreads: Int = 1,
    provider: String = "cpu",
    debug: Int = 0,
    modelType: String = "",
    modelingUnit: String = "cjkchar",
    bpeVocab: String = "",
    teleSpeechCtc: String = "",
    senseVoice: SherpaOnnxOfflineSenseVoiceModelConfig = sherpaOnnxOfflineSenseVoiceModelConfig(),
    moonshine: SherpaOnnxOfflineMoonshineModelConfig = sherpaOnnxOfflineMoonshineModelConfig(),
    fireRedAsr: SherpaOnnxOfflineFireRedAsrModelConfig = sherpaOnnxOfflineFireRedAsrModelConfig(),
    dolphin: SherpaOnnxOfflineDolphinModelConfig = sherpaOnnxOfflineDolphinModelConfig(),
    zipformerCtc: SherpaOnnxOfflineZipformerCtcModelConfig = sherpaOnnxOfflineZipformerCtcModelConfig(),
    canary: SherpaOnnxOfflineCanaryModelConfig = sherpaOnnxOfflineCanaryModelConfig(),
    wenetCtc: SherpaOnnxOfflineWenetCtcModelConfig = sherpaOnnxOfflineWenetCtcModelConfig(),
    omnilingual: SherpaOnnxOfflineOmnilingualAsrCtcModelConfig = sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(),
    medasr: SherpaOnnxOfflineMedAsrCtcModelConfig = sherpaOnnxOfflineMedAsrCtcModelConfig(),
    funasrNano: SherpaOnnxOfflineFunASRNanoModelConfig = sherpaOnnxOfflineFunASRNanoModelConfig(),
    fireRedAsrCtc: SherpaOnnxOfflineFireRedAsrCtcModelConfig = sherpaOnnxOfflineFireRedAsrCtcModelConfig()
) -> SherpaOnnxOfflineModelConfig {
    return SherpaOnnxOfflineModelConfig(
        transducer: transducer,
        paraformer: paraformer,
        nemo_ctc: nemoCtc,
        whisper: whisper,
        tdnn: tdnn,
        tokens: toCPointer(tokens),
        num_threads: Int32(numThreads),
        debug: Int32(debug),
        provider: toCPointer(provider),
        model_type: toCPointer(modelType),
        modeling_unit: toCPointer(modelingUnit),
        bpe_vocab: toCPointer(bpeVocab),
        telespeech_ctc: toCPointer(teleSpeechCtc),
        sense_voice: senseVoice,
        moonshine: moonshine,
        fire_red_asr: fireRedAsr,
        dolphin: dolphin,
        zipformer_ctc: zipformerCtc,
        canary: canary,
        wenet_ctc: wenetCtc,
        omnilingual: omnilingual,
        medasr: medasr,
        funasr_nano: funasrNano,
        fire_red_asr_ctc: fireRedAsrCtc
    )
}

// MARK: - Offline Recognizer Config

public func sherpaOnnxOfflineRecognizerConfig(
    featConfig: SherpaOnnxFeatureConfig,
    modelConfig: SherpaOnnxOfflineModelConfig,
    lmConfig: SherpaOnnxOfflineLMConfig = sherpaOnnxOfflineLMConfig(),
    decodingMethod: String = "greedy_search",
    maxActivePaths: Int = 4,
    hotwordsFile: String = "",
    hotwordsScore: Float = 1.5,
    ruleFsts: String = "",
    ruleFars: String = "",
    blankPenalty: Float = 0.0,
    hr: SherpaOnnxHomophoneReplacerConfig = sherpaOnnxHomophoneReplacerConfig()
) -> SherpaOnnxOfflineRecognizerConfig {
    return SherpaOnnxOfflineRecognizerConfig(
        feat_config: featConfig,
        model_config: modelConfig,
        lm_config: lmConfig,
        decoding_method: toCPointer(decodingMethod),
        max_active_paths: Int32(maxActivePaths),
        hotwords_file: toCPointer(hotwordsFile),
        hotwords_score: hotwordsScore,
        rule_fsts: toCPointer(ruleFsts),
        rule_fars: toCPointer(ruleFars),
        blank_penalty: blankPenalty,
        hr: hr
    )
}

// MARK: - Offline Recognition Result

public class SherpaOnnxOfflineRecognitionResult {
    let result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>

    init(result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>) {
        self.result = result
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizerResult(result)
    }

    public lazy var text: String = {
        guard let cstr = result.pointee.text else { return "" }
        return String(cString: cstr)
    }()
}

// MARK: - Offline Recognizer

public class SherpaOnnxOfflineRecognizer {
    private let recognizer: OpaquePointer

    public init(config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>) {
        guard let ptr = SherpaOnnxCreateOfflineRecognizer(config) else {
            fatalError("Failed to create SherpaOnnxOfflineRecognizer")
        }
        self.recognizer = ptr
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    public func decode(samples: [Float], sampleRate: Int = 16000) -> SherpaOnnxOfflineRecognitionResult {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            fatalError("Failed to create offline stream")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), samples, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream) else {
            fatalError("Failed to get offline recognition result")
        }

        return SherpaOnnxOfflineRecognitionResult(result: resultPtr)
    }
}
