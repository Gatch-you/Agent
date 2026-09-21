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

    struct Update: Sendable {
        let text: String
        let isFinal: Bool
    }

    private var transcriber: SpeechTranscriber?
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
    func prepare(locale: Locale = Locale(identifier: "en-US"),
                 naturalFormat: AVAudioFormat?,
                 onProgress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        onProgress?(0, "SpeechTranscriber の利用可否を確認中")
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        onProgress?(0, "ロケール確認中")
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale
        }

        let t = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)

        let preStatus = await AssetInventory.status(forModules: [t])
        let reserved = await AssetInventory.reservedLocales
        onProgress?(0, "事前状態: status=\(preStatus) reservedLocales=\(reserved.map(\.identifier))")

        // 既存の予約が壊れている/中途半端な可能性を疑い、一度解放してから
        // インストール要求をやり直す。release は失敗しても無視してよい
        // （そもそも予約が無ければ false が返るだけ）。
        for locale in reserved {
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

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [t], considering: naturalFormat
        ) else { throw TranscriberError.noCompatibleFormat }

        let a = SpeechAnalyzer(modules: [t])
        try await a.prepareToAnalyze(in: format)

        self.transcriber = t
        self.analyzer = a
        self.analyzerFormat = format
    }

    /// 認識を開始し、更新を AsyncStream で返す。
    func start() async throws -> AsyncStream<Update> {
        guard let analyzer, let transcriber else { throw TranscriberError.unavailable }

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = inputCont
        try await analyzer.start(inputSequence: inputStream)

        let (updates, updatesCont) = AsyncStream<Update>.makeStream()
        consumerTask = Task {
            do {
                for try await result in transcriber.results {
                    updatesCont.yield(
                        Update(text: String(result.text.characters), isFinal: result.isFinal)
                    )
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
