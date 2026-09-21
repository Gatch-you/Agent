import AVFoundation
import Foundation

/// 音声入出力の土台。
///
/// このプロトタイプの目的の半分はこのファイルにある。
/// ここで **AEC（エコーキャンセル）が効くこと** を確認できなければ、
/// barge-in（AI の発話中にユーザーが割り込む）は実装できない。
///
/// 要点は3つ:
///  1. `AVAudioSession` を `.playAndRecord` + `.voiceChat` にする
///  2. `AVAudioEngine` の input/output で `setVoiceProcessingEnabled(true)` を呼ぶ
///     ← これが実際に AEC を有効化する API。セッションのモード設定だけでは不十分
///  3. 2 を呼ぶと**入力フォーマットが変わる**ので、必ず有効化した「後に」
///     `inputNode.outputFormat(forBus:)` を読む
final class AudioEngineHost: @unchecked Sendable {

    enum HostError: Error, LocalizedError {
        case micPermissionDenied
        case voiceProcessingUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .micPermissionDenied:
                return "マイクの使用が許可されていません"
            case .voiceProcessingUnavailable(let m):
                return "Voice Processing を有効化できません: \(m)"
            }
        }
    }

    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    /// 生成した音声の再生サンプルレート（Kokoro は 24 kHz 固定）
    private let ttsSampleRate: Double = 24_000

    // 入力フォーマット（voice processing 有効化「後」の実際の値）
    private(set) var inputFormat: AVAudioFormat?
    private(set) var voiceProcessingEnabled = false

    /// 直近の入力 RMS（dBFS）。AEC の効きを測るのに使う。
    /// オーディオスレッドから書かれるため atomic な read/write に留める。
    private let rmsLock = NSLock()
    private var _currentRMSdB: Float = -120
    var currentRMSdB: Float {
        rmsLock.lock(); defer { rmsLock.unlock() }
        return _currentRMSdB
    }

    /// マイクバッファの購読者。オーディオスレッドから呼ばれる。
    /// **@MainActor のオブジェクトに触れないこと。**
    var onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    // MARK: - セットアップ

    func requestMicPermission() async throws {
        let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard granted else { throw HostError.micPermissionDenied }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()

        // .voiceChat モードが OS の音声処理パス（AEC / AGC / ノイズ抑制）を選択する。
        // .defaultToSpeaker を入れないとレシーバー（耳元のスピーカー）から鳴り、
        // ハンズフリーでの検証にならない。
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let output = engine.outputNode

        // ★ ここが AEC の本体。engine.start() より前、タップを張る前に呼ぶ。
        do {
            try input.setVoiceProcessingEnabled(true)
            try output.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingBypassed = false
            // AI の発話中に他アプリの音を下げすぎないようにする（任意）
            input.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
            voiceProcessingEnabled = true
        } catch {
            voiceProcessingEnabled = false
            throw HostError.voiceProcessingUnavailable(error.localizedDescription)
        }

        // ★ 有効化「後」に読む。有効化でフォーマットが変わることがある。
        let format = input.outputFormat(forBus: 0)
        inputFormat = format

        engine.attach(player)
        // TTS は 24 kHz mono。mixer が出力フォーマットへ変換してくれる。
        let ttsFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ttsSampleRate,
            channels: 1,
            interleaved: false
        )!
        engine.connect(player, to: engine.mainMixerNode, format: ttsFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateRMS(buffer)
            self.onMicBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - 計測

    private func updateRMS(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        rmsLock.lock(); _currentRMSdB = db; rmsLock.unlock()
    }

    // MARK: - 再生

    private var playbackGeneration = 0

    /// Float32 mono 24 kHz のサンプル列を再生する。
    /// `interrupt()` が呼ばれると即座に止まる。
    func play(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ttsSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        playbackGeneration += 1
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: [])
    }

    /// barge-in 時の即時停止。
    func interrupt() {
        playbackGeneration += 1
        player.stop()
        player.play()   // 次の発話をすぐ受けられるようにしておく
    }

    var isPlaying: Bool { player.isPlaying }
}
