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
            try host.start()

            voiceProcessingEnabled = host.voiceProcessingEnabled
            if let f = host.inputFormat {
                inputFormatDescription =
                    "\(Int(f.sampleRate)) Hz / \(f.channelCount) ch"
            }
            add("Voice Processing: \(voiceProcessingEnabled ? "有効" : "無効")")
            add("入力フォーマット: \(inputFormatDescription)")

            add("SpeechAnalyzer 準備中…（初回は音声認識モデルのDLで時間がかかる）")
            let t = Transcriber()
            try await t.prepare(naturalFormat: host.inputFormat) { [weak self] fraction, stage in
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
            // volatile は「置換」。追記すると単語が重複する。
            finalizedText += (finalizedText.isEmpty ? "" : " ") + u.text
            volatileText = ""
            if state == .listening, !u.text.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { await respond() }
            }
        } else {
            volatileText = u.text
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
