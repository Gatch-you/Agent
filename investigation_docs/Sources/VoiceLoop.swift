import AVFoundation
import Foundation
import Observation
import Speech

/// 会話ループの状態機械と、AEC 検証ロジック。
///
/// 本番の設計（設計書 §07）では idle → listening → thinking → speaking を
/// XState か reducer で明示的にモデリングする。ここはその最小版。
///
/// **LLM は繋がない。** このプロトタイプで潰したいリスクは音声の往復であって、
/// 応答生成ではない。thinking は定型応答で代替し、検証を決定論的にする。
@available(iOS 26.0, *)
@MainActor
@Observable
final class VoiceLoop {

    enum State: String {
        case idle       = "idle"
        case preparing  = "preparing"
        case listening  = "listening"
        case thinking   = "thinking"
        case speaking   = "speaking"
        case failed     = "failed"
    }

    // 表示用
    private(set) var state: State = .idle
    private(set) var finalizedText = ""
    private(set) var volatileText = ""
    private(set) var log: [String] = []
    private(set) var errorMessage: String?

    /// true の間は確定テキストが出ても定型応答（TTS再生）を挟まない。
    /// 連続して話した内容がすべて文字起こしされるかだけを、
    /// 会話ループに邪魔されず確認するためのモード。
    var transcribeOnly = false

    /// STT のロケール。英語だけが固まるのか（地域制限説）、未インストールの
    /// ロケールならどれでも固まるのか（ダウンロード経路の問題）を切り分けるため、
    /// 画面から差し替えられるようにしている。
    var sttLocaleID = "en-US"

    /// true なら AVAudioEngine（voice processing）を起動する前にアセットを
    /// インストールする。音声セッションがダウンロードを妨げていないかの切り分け用。
    var installAssetsBeforeAudio = false

    /// false ならインストール要求前の予約解放をしない。解放直後の再要求が
    /// ダウンロードを止めていないかの切り分け用。
    var releaseReservationsBeforeInstall = true

    /// true ならインストール要求の前に旧 API（SFSpeechRecognizer）の
    /// オンデバイス認識を一度起動する。切り分け用。
    var probeLegacyOnDevice = false

    /// SpeechAnalyzer に載せる認識モジュール。SpeechTranscriber の資産DLが
    /// どのロケールでも進まないため、既に端末にある可能性が高い
    /// DictationTranscriber（キーボード音声入力と同系統）と切り替えて比べる。
    var sttEngine: Transcriber.Engine = .speech

    // 計測値
    private(set) var inputFormatDescription = "—"
    private(set) var voiceProcessingEnabled = false
    private(set) var silenceRMSdB: Float = -120      // 無音時の基準値
    private(set) var playbackRMSdB: Float = -120     // TTS 再生中の値
    private(set) var liveRMSdB: Float = -120
    private(set) var ttsReport = "（まだ計測なし）"
    private(set) var aecVerdict: String?

    /// AEC が効いていれば、TTS 再生中でもマイクの RMS は無音時とほとんど変わらない。
    /// 差がこの値を超えたら自分の声を拾っている＝ AEC が効いていない。
    private let aecFailThresholdDB: Float = 12

    private let host = AudioEngineHost()
    private let tts = TtsEngine()
    private var transcriber: Transcriber?
    private var updatesTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var lastLoggedSTTProgress = -100
    private var lastLoggedSTTStage = ""

    // barge-in 判定
    private var bargeInFrames = 0
    private let bargeInFramesRequired = 8   // 約 150〜200 ms 相当

    private let replies = [
        "That's interesting. How long have you been doing that?",
        "I see what you mean. Could you tell me a bit more?",
        "Nice. What made you decide to try it?",
        "Got it. And how did that turn out in the end?",
    ]
    private var replyIndex = 0

    // MARK: - ライフサイクル

    func startSession() async {
        guard state == .idle || state == .failed else { return }
        state = .preparing
        errorMessage = nil
        add("セッション開始")

        do {
            try await host.requestMicPermission()

            let t = Transcriber()
            if installAssetsBeforeAudio {
                try await installSTTAssets(t)
            }

            try host.start()

            voiceProcessingEnabled = host.voiceProcessingEnabled
            if let f = host.inputFormat {
                inputFormatDescription =
                    "\(Int(f.sampleRate)) Hz / \(f.channelCount) ch"
            }
            add("Voice Processing: \(voiceProcessingEnabled ? "有効" : "無効")")
            add("入力フォーマット: \(inputFormatDescription)")

            if !installAssetsBeforeAudio {
                try await installSTTAssets(t)
            }

            // AVAudioEngine 起動 → 実際のマイクフォーマットが確定してから
            // SpeechAnalyzer を準備する（naturalFormat にマイクの実フォーマットを
            // 渡すことで、変換なし/最小限で済むフォーマットを選ばせる）。
            // アセットのインストールだけは上で起動前に移せるが、naturalFormat は
            // nil にしないこと（nil にすると認識が全く動かなくなった）。
            try await t.prepare(naturalFormat: host.inputFormat)
            transcriber = t
            add("SpeechAnalyzer 準備完了")

            // マイクバッファをアナライザへ。タップはオーディオスレッドなので、
            // ここでは値をコピーしてから actor に渡す。
            host.onMicBuffer = { [weak self] buffer in
                guard let self, let copy = buffer.deepCopy() else { return }
                Task { await self.transcriber?.feed(copy) }
            }

            let updates = try await t.start()
            updatesTask = Task { [weak self] in
                for await u in updates { await self?.apply(u) }
            }

            startMetering()

            add("Kokoro をロード中…（初回は重みのDLで時間がかかる）")
            try await tts.load { [weak self] fraction, message in
                Task { @MainActor in
                    self?.add(String(format: "Kokoro: %@ (%.0f%%)", message, fraction * 100))
                }
            }
            ttsReport = await tts.report()
            add("Kokoro ロード完了")

            state = .listening
        } catch {
            errorMessage = error.localizedDescription
            add("エラー: \(error.localizedDescription)")
            state = .failed
        }
    }

    private func installSTTAssets(_ t: Transcriber) async throws {
        if probeLegacyOnDevice {
            await Transcriber.probeLegacyOnDevice(locale: Locale(identifier: sttLocaleID)) { [weak self] m in
                Task { @MainActor in self?.add(m) }
            }
        }
        add("STT アセット準備中… engine=\(sttEngine.rawValue) locale=\(sttLocaleID) タイミング=\(installAssetsBeforeAudio ? "音声エンジン起動前" : "音声エンジン起動後") 予約解放=\(releaseReservationsBeforeInstall)")
        try await t.installAssets(locale: Locale(identifier: sttLocaleID),
                                  engine: sttEngine,
                                  releaseReservations: releaseReservationsBeforeInstall) { [weak self] fraction, stage in
            Task { @MainActor in
                guard let self else { return }
                let percent = Int(fraction * 100)
                // 段階が変わった時、または10%刻みで進んだ時だけログに出す
                // （毎300msそのまま出すとログが埋まってしまうため）
                if stage != self.lastLoggedSTTStage
                    || percent / 10 != self.lastLoggedSTTProgress / 10
                    || percent == 100 {
                    self.lastLoggedSTTStage = stage
                    self.lastLoggedSTTProgress = percent
                    self.add("STT: \(stage) (\(percent)%)")
                }
            }
        }
    }

    func stopSession() async {
        updatesTask?.cancel(); updatesTask = nil
        meterTask?.cancel(); meterTask = nil
        await transcriber?.finish()
        transcriber = nil
        host.stop()
        state = .idle
        add("セッション終了")
    }

    // MARK: - メータリング（AEC 判定の基礎データ）

    private func startMetering() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let db = self.host.currentRMSdB
                self.liveRMSdB = db

                switch self.state {
                case .listening:
                    // 無音時の基準値をゆっくり追従させる（発話中は上がるので下側だけ採用）
                    if db < self.silenceRMSdB || self.silenceRMSdB < -119 {
                        self.silenceRMSdB = db
                    } else {
                        self.silenceRMSdB += (db - self.silenceRMSdB) * 0.005
                    }
                case .speaking:
                    self.playbackRMSdB = max(self.playbackRMSdB, db)
                    self.checkBargeIn(db)
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func checkBargeIn(_ db: Float) {
        // 自分の TTS を拾っているのか、人が話しているのかを RMS だけで見る。
        // AEC が効いていれば TTS はほぼ乗らないので、閾値超え＝人の発話とみなせる。
        if db > silenceRMSdB + 15 {
            bargeInFrames += 1
            if bargeInFrames >= bargeInFramesRequired {
                bargeInFrames = 0
                add("barge-in 検出 → 再生を中断")
                host.interrupt()
                state = .listening
            }
        } else {
            bargeInFrames = 0
        }
    }

    // MARK: - 認識結果

    private func apply(_ u: Transcriber.Update) {
        if u.isFinal {
            add("認識(確定): \(u.text)")
            // volatile は「置換」。追記すると単語が重複する。
            finalizedText += (finalizedText.isEmpty ? "" : " ") + u.text
            volatileText = ""
            if !transcribeOnly, state == .listening, !u.text.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { await respond() }
            }
        } else {
            volatileText = u.text
        }
    }

    // MARK: - STT 自己診断

    /// Kokoro で合成した英語音声を、マイクとは別の Transcriber に直接流して
    /// 文字起こし結果を確認する。マイクや端末の置き場所に左右されない
    /// 決定論的な確認用。listening 状態（Kokoro ロード済み）で呼ぶこと。
    func runSTTSelfTest() async {
        let text = "Hello. I would like to practice my English conversation today."
        add("── STT 自己診断: engine=\(sttEngine.rawValue) locale=\(sttLocaleID) ──")
        add("入力テキスト: \(text)")
        do {
            let samples = try await tts.synthesize(text)
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
                  let dst = buf.floatChannelData?[0]
            else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }

            let t = Transcriber()
            try await t.installAssets(locale: Locale(identifier: sttLocaleID), engine: sttEngine,
                                      releaseReservations: false)
            try await t.prepare(naturalFormat: fmt)
            let updates = try await t.start()
            await t.feed(buf)
            let collector = Task {
                var finals: [String] = []
                for await u in updates where u.isFinal { finals.append(u.text) }
                return finals.joined(separator: " ")
            }
            await t.finish()
            add("自己診断 認識結果: \(await collector.value)")
        } catch {
            add("自己診断 失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 応答（LLM の代わりに定型文）

    private func respond() async {
        state = .thinking
        let reply = replies[replyIndex % replies.count]
        replyIndex += 1
        add("応答: \(reply)")

        do {
            let audio = try await tts.synthesize(reply)
            ttsReport = await tts.report()
            playbackRMSdB = -120
            state = .speaking
            host.play(samples: audio)

            // 再生の終了を音声長から概算して listening に戻す。
            // 本番では AVAudioPlayerNode の completion handler を使う。
            let seconds = Double(audio.count) / 24_000.0
            try? await Task.sleep(for: .seconds(seconds + 0.2))
            if state == .speaking {
                evaluateAEC()
                state = .listening
            }
        } catch {
            add("TTS エラー: \(error.localizedDescription)")
            state = .listening
        }
    }

    // MARK: - AEC 単体テスト

    /// 無言のまま TTS を再生し、再生中のマイク入力レベルを測る。
    /// **このテスト中は何も喋らないこと。**
    func runAECTest() async {
        guard state == .listening else { return }
        add("── AEC 検証開始。話さずに待ってください ──")

        // 基準値を取り直す
        silenceRMSdB = liveRMSdB
        try? await Task.sleep(for: .milliseconds(600))
        let baseline = liveRMSdB
        silenceRMSdB = baseline

        let text = "This is an echo cancellation test. Please stay silent while I speak."
        do {
            let audio = try await tts.synthesize(text)
            ttsReport = await tts.report()
            playbackRMSdB = -120
            state = .speaking
            host.play(samples: audio)
            let seconds = Double(audio.count) / 24_000.0
            try? await Task.sleep(for: .seconds(seconds + 0.2))
            state = .listening
            evaluateAEC()
        } catch {
            add("AEC 検証失敗: \(error.localizedDescription)")
            state = .listening
        }
    }

    private func evaluateAEC() {
        let delta = playbackRMSdB - silenceRMSdB
        let ok = delta < aecFailThresholdDB
        aecVerdict = String(
            format: "無音 %.1f dB → 再生中 %.1f dB（差 %.1f dB）… %@",
            silenceRMSdB, playbackRMSdB, delta,
            ok ? "AEC 有効" : "AEC が効いていない疑い"
        )
        add(aecVerdict!)
    }

    // MARK: -

    private func add(_ s: String) {
        // stdout にも出す。`xcrun devicectl device process launch --console`
        // でMacのターミナルから実機の進行状況をそのまま見られるようにするため。
        print("[VoiceLoop] \(s)")
        log.insert(s, at: 0)
        if log.count > 80 { log.removeLast() }
    }
}

extension AVAudioPCMBuffer {
    /// タップのバッファはコールバック後に再利用されるため、
    /// 別スレッドへ渡す前に必ず所有権のあるコピーを取る。
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength),
              let src = floatChannelData, let dst = copy.floatChannelData
        else { return nil }
        copy.frameLength = frameLength
        for ch in 0..<Int(format.channelCount) {
            dst[ch].update(from: src[ch], count: Int(frameLength))
        }
        return copy
    }
}

/// SDK 側で `Sendable` に準拠していない。`deepCopy()` で得たバッファは
/// 呼び出し元が排他的に所有する（他に参照を持つ者がいない）ことが
/// 呼び出し規約上保証されているため、境界を跨いで送っても安全。
extension AVAudioPCMBuffer: @unchecked Sendable {}
