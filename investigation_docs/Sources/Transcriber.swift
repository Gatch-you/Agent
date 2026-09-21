import AVFoundation
import Foundation
import Speech

/// iOS 26 の `SpeechAnalyzer` / `SpeechTranscriber` を使ったオンデバイス STT。
///
/// ハマりどころ（実装前に把握しておくこと）:
///  - アナライザは**リサンプリングしてくれない**。マイクのフォーマットと
///    `bestAvailableAudioFormat` が違う場合は `AVAudioConverter` が必須。
///  - タップから渡されたバッファはコールバック後に**再利用される**。
///    キューに積むなら必ずコピーを取る。
///  - volatile（暫定）結果は「追記」ではなく「置換」。追記すると単語が重複する。
///  - 停止は順序が重要: タップ停止 → continuation.finish()
///    → finalizeAndFinishThroughEndOfInput() → 結果consumerの完了を待つ。
///    consumer を先に殺すと最後の単語が消える。
@available(iOS 26.0, *)
actor Transcriber {

    enum TranscriberError: Error, LocalizedError {
        case unavailable, unsupportedLocale, assetsNotInstalled, noCompatibleFormat

        var errorDescription: String? {
            switch self {
            case .unavailable:         return "この端末では SpeechTranscriber を利用できません"
            case .unsupportedLocale:   return "指定ロケールに対応していません"
            case .assetsNotInstalled:  return "音声認識モデルのインストールに失敗しました"
            case .noCompatibleFormat:  return "互換の音声フォーマットが見つかりません"
            }
        }
    }

    /// どちらも SpeechAnalyzer に載るモジュールだが、モデル資産の系統が違う。
    /// SpeechTranscriber は新しい汎用モデル、DictationTranscriber は
    /// キーボード音声入力・旧 API（SFSpeechRecognizer）と同系統のモデル。
    enum Engine: String, Sendable {
        case speech, dictation
    }

    struct Update: Sendable {
        let text: String
        let isFinal: Bool
    }

    private var speechTranscriber: SpeechTranscriber?
    private var dictationTranscriber: DictationTranscriber?
    private var module: (any SpeechModule)? { speechTranscriber ?? dictationTranscriber }
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private(set) var analyzerFormat: AVAudioFormat?

    /// 初回はモデル資産のダウンロードが走ることがある（数十MB）。
    /// 「オンデバイス＝準備不要」ではない点に注意。
    /// `onProgress` は `AssetInstallationRequest` が `ProgressReporting` に
    /// 準拠している（`.progress` が Foundation の `Progress`）ことを利用して、
    /// ダウンロードが進んでいるかを外から見えるようにするために追加した。
    ///
    /// `prepare` から切り離してあるのは、AVAudioEngine（voice processing）の
    /// 起動前後どちらでインストールするかを切り替えて、ハングの原因を
    /// 切り分けられるようにするため。
    func installAssets(locale: Locale,
                       engine: Engine = .speech,
                       releaseReservations: Bool = true,
                       onProgress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        onProgress?(0, "エンジン=\(engine.rawValue) の利用可否を確認中")
        let t: any SpeechModule
        let supported: Locale
        let installedLocales: [Locale]
        switch engine {
        case .speech:
            guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
            onProgress?(0, "ロケール確認中")
            guard let s = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw TranscriberError.unsupportedLocale
            }
            // preset を変えてもハングは再現したため、リアルタイム性を優先する
            // .progressiveTranscription に戻す（ハングの原因は未確定。地域制限説は
            // 「ja-JP は既にインストール済みだった」可能性と交絡している）。
            let st = SpeechTranscriber(locale: s, preset: .progressiveTranscription)
            speechTranscriber = st
            t = st
            supported = s
            installedLocales = await SpeechTranscriber.installedLocales
        case .dictation:
            onProgress?(0, "ロケール確認中")
            guard let s = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw TranscriberError.unsupportedLocale
            }
            let dt = DictationTranscriber(locale: s, preset: .progressiveLongDictation)
            dictationTranscriber = dt
            t = dt
            supported = s
            installedLocales = await DictationTranscriber.installedLocales
        }

        let preStatus = await AssetInventory.status(forModules: [t])
        let reserved = await AssetInventory.reservedLocales
        let alreadyInstalled = installedLocales.map(\.identifier).contains(supported.identifier)
        onProgress?(0, "事前状態: locale=\(supported.identifier) status=\(preStatus) reservedLocales=\(reserved.map(\.identifier)) installed=\(alreadyInstalled)")
        // 「ja-JP は動く」が、単にダウンロード不要だった（既にインストール済み）
        // だけなのかを判別するため、インストール済みロケールを全部出す。
        onProgress?(0, "インストール済み(\(engine.rawValue)): \(installedLocales.map(\.identifier).sorted())")

        // 既存の予約が壊れている/中途半端な可能性を疑い、一度解放してから
        // インストール要求をやり直す。release は失敗しても無視してよい
        // （そもそも予約が無ければ false が返るだけ）。
        for locale in reserved where releaseReservations {
            let released = await AssetInventory.release(reservedLocale: locale)
            onProgress?(0, "予約解放: \(locale.identifier) -> \(released)")
        }

        onProgress?(0, "アセットのインストール要求を確認中")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            onProgress?(0, "アセットのダウンロード開始")
            let progress = request.progress
            let progressTask = Task {
                while !progress.isFinished && !Task.isCancelled {
                    onProgress?(progress.fractionCompleted, "ダウンロード中")
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            try await request.downloadAndInstall()
            progressTask.cancel()
            onProgress?(1.0, "ダウンロード完了")
        } else {
            onProgress?(1.0, "アセットは既にインストール済み")
        }
        guard await AssetInventory.status(forModules: [t]) == .installed else {
            throw TranscriberError.assetsNotInstalled
        }
    }

    /// 旧 API（SFSpeechRecognizer）でオンデバイス認識を一度起動し、反応をログに出す。
    /// 旧 API 経由なら同じロケールのアセットが入るか（＝ AssetInventory 経由の
    /// ダウンロードだけが止まっているのか）を切り分けるためのプローブ。
    /// 1秒の無音を流して endAudio し、結果かエラーを最大15秒待つ。
    static func probeLegacyOnDevice(locale: Locale,
                                    log: @escaping @Sendable (String) -> Void) async {
        let auth = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        log("旧API 認可状態: \(auth.rawValue)（3 = authorized）")
        guard auth == .authorized, let r = SFSpeechRecognizer(locale: locale) else {
            log("旧API: SFSpeechRecognizer を使えない")
            return
        }
        log("旧API: isAvailable=\(r.isAvailable) supportsOnDeviceRecognition=\(r.supportsOnDeviceRecognition)")

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000),
              let samples = buf.floatChannelData?[0]
        else { return }
        buf.frameLength = 16_000
        samples.update(repeating: 0, count: 16_000)

        let (events, cont) = AsyncStream<String>.makeStream()
        let task = r.recognitionTask(with: req) { result, error in
            if let error {
                cont.yield("旧API: エラー \(error)")
                cont.finish()
            } else if let result, result.isFinal {
                cont.yield("旧API: 完了 '\(result.bestTranscription.formattedString)'")
                cont.finish()
            }
        }
        req.append(buf)
        req.endAudio()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            cont.yield("旧API: 15秒応答なし")
            cont.finish()
        }
        for await e in events { log(e) }
        timeout.cancel()
        task.cancel()
    }

    /// `installAssets` 済みであることが前提。
    func prepare(naturalFormat: AVAudioFormat?) async throws {
        guard let t = module else { throw TranscriberError.assetsNotInstalled }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [t], considering: naturalFormat
        ) else { throw TranscriberError.noCompatibleFormat }

        let a = SpeechAnalyzer(modules: [t])
        try await a.prepareToAnalyze(in: format)

        self.analyzer = a
        self.analyzerFormat = format
    }

    /// 認識を開始し、更新を AsyncStream で返す。
    func start() async throws -> AsyncStream<Update> {
        guard let analyzer, module != nil else { throw TranscriberError.unavailable }
        let speechTranscriber = self.speechTranscriber
        let dictationTranscriber = self.dictationTranscriber

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = inputCont
        try await analyzer.start(inputSequence: inputStream)

        let (updates, updatesCont) = AsyncStream<Update>.makeStream()
        consumerTask = Task {
            do {
                if let speechTranscriber {
                    for try await result in speechTranscriber.results {
                        updatesCont.yield(
                            Update(text: String(result.text.characters), isFinal: result.isFinal)
                        )
                    }
                } else if let dictationTranscriber {
                    for try await result in dictationTranscriber.results {
                        updatesCont.yield(
                            Update(text: String(result.text.characters), isFinal: result.isFinal)
                        )
                    }
                }
            } catch {
                // 認識側のエラーはストリーム終了として扱う
            }
            updatesCont.finish()
        }
        return updates
    }

    /// マイクバッファを流し込む。フォーマットが違えば変換する。
    /// オーディオスレッドから直接呼ばず、コピーしたバッファを渡すこと。
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let continuation, let target = analyzerFormat else { return }

        let converted: AVAudioPCMBuffer
        if buffer.format == target {
            converted = buffer
        } else {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            // 変換失敗を黙って捨てると「録れているのに文字が出ない」状態になる
            guard error == nil, out.frameLength > 0 else { return }
            converted = out
        }

        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// 正常停止。最後の単語を取りこぼさないための順序を守る。
    func finish() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await consumerTask?.value
        consumerTask = nil
    }
}
