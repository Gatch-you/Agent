import AVFoundation
import Foundation
import KokoroTTS

/// Native TTS engine behind the `voice_loop/tts` platform channel
/// (`ios/Runner/AppDelegate.swift`), backed by the on-device Kokoro-82M
/// model (`soniqo/speech-swift`'s `KokoroTTS` package) — the adopted TTS
/// choice per design doc §09 (adoption + real-device performance already
/// confirmed via `investigation_docs/kokoro_tts_listening_test.ipynb` and
/// VoiceLoopLab), replacing the walking-skeleton's `AVSpeechSynthesizer`
/// bridge. See `.claude/specs/kokoro-tts-bridge.md`.
///
/// Kokoro only returns raw 24kHz mono Float32 samples — unlike
/// `AVSpeechSynthesizer`, which manages its own playback, this bridge owns
/// real audio output for the first time, via its own `AVAudioEngine`/
/// `AVAudioPlayerNode`. It deliberately never touches `AVAudioSession`
/// category or activation: `DictationTranscriberBridge` already keeps a
/// persistent `.playAndRecord` session running continuously through TTS
/// playback (read that file's doc comment before changing audio session
/// code anywhere in this app) — this engine just renders into that already-
/// active session, the same way the old `AVSpeechSynthesizer`-based bridge
/// implicitly did.
actor KokoroTtsBridge {

    enum BridgeError: Error, LocalizedError {
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .emptyAudio: return "Kokoro produced no audio samples"
            }
        }
    }

    private static let sampleRate: Double = 24_000
    private static let voice = "af_heart"

    /// Flip to true if audio ever sounds broken — some iOS 26 builds have a
    /// known ANE compiler bug with this model (per speech-swift's own docs)
    /// that produces bad output; .cpuAndGPU is the documented workaround.
    /// Not wired to any UI toggle (no diagnostics panel in this app, unlike
    /// VoiceLoopLab).
    private static let bypassANE = false

    private var model: KokoroTTSModel?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineStarted = false

    private func loadModelIfNeeded() async throws -> KokoroTTSModel {
        if let model { return model }

        // Bundled offline at build time (~318MB, ios/Runner/Resources/KokoroModel)
        // — offlineMode: true means no network access, matching TtsEngine.swift's
        // proven VoiceLoopLab setup.
        let bundledModelDir = Bundle.main.resourceURL?.appendingPathComponent("KokoroModel")
        let useBundled = bundledModelDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        let loaded = Self.bypassANE
            ? try await KokoroTTSModel.fromPretrained(
                cacheDir: useBundled ? bundledModelDir : nil,
                offlineMode: useBundled,
                computeUnits: .cpuAndGPU)
            : try await KokoroTTSModel.fromPretrained(
                cacheDir: useBundled ? bundledModelDir : nil,
                offlineMode: useBundled)

        model = loaded
        return loaded
    }

    private func startEngineIfNeeded() throws {
        guard !engineStarted else { return }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        engineStarted = true
    }

    /// Synthesizes `text` and plays it back, suspending until playback
    /// actually finishes (not just until the buffer is scheduled).
    func speak(_ text: String) async throws {
        let model = try await loadModelIfNeeded()
        // Argument labels per speech-swift's KokoroTTSModel API; there's
        // also a synthesize(text:voice:speed:) overload if speed control is
        // ever needed.
        let samples = try model.synthesize(text: text, voice: Self.voice)
        guard !samples.isEmpty else { throw BridgeError.emptyAudio }

        try startEngineIfNeeded()
        await play(samples)
    }

    private func play(_ samples: [Float]) async {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        if !player.isPlaying {
            player.play()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // .dataPlayedBack (not the .dataConsumed default) so this only
            // resumes once the audio has actually finished sounding, not
            // just once the buffer has been handed off internally.
            player.scheduleBuffer(
                buffer,
                at: nil,
                options: [],
                completionCallbackType: .dataPlayedBack
            ) { _ in
                continuation.resume()
            }
        }
    }

    /// Stops playback immediately — the Kokoro-bridge equivalent of the old
    /// `synthesizer.stopSpeaking(at: .immediate)`.
    func stop() {
        player.stop()
    }
}
