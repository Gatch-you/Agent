import AVFoundation
import Foundation
import Speech

/// Native STT engine behind the `voice_loop/stt` platform channel
/// (`ios/Runner/AppDelegate.swift`), backed by Apple's `DictationTranscriber`
/// (iOS 26 `Speech`/`SpeechAnalyzer` framework) — the adopted STT choice per
/// `.claude/CLAUDE.md`'s STT finding and design doc §13.
///
/// This is a simplified port of `investigation_docs/Sources/Transcriber.swift`
/// + `AudioEngineHost.swift` from the VoiceLoopLab prototype: locale is fixed
/// to en-US (see `.claude/specs/dictation-transcriber-stt-bridge.md` — Out of
/// scope), and there's no AEC/voice-processing setup, because this app's
/// state machine never listens while TTS is speaking.
///
/// **Session lifetime, and why it's shaped this way**: the underlying
/// `SpeechAnalyzer`/`DictationTranscriber`/`AVAudioEngine` session is created
/// ONCE per app run and never torn down between conversational turns —
/// matching VoiceLoopLab's proven-stable usage exactly. An earlier version of
/// this bridge called `finalizeAndFinishThroughEndOfInput()` and rebuilt the
/// whole session after every single utterance; that crashed on-device inside
/// the Speech framework's own worker state machine (`EXC_BREAKPOINT` in
/// `TranscriberCommon.worker.setter`) — VoiceLoopLab never exercises that
/// restart-per-turn pattern, only Apple's own framework code was on the
/// stack, and the crash reproduced consistently, so it's treated as a
/// per-turn-restart-triggered SDK bug to avoid rather than something to fix
/// on this side. `startListening()`/`stopListening()` (called once per turn
/// by `voice_loop_screen.dart`) now just resume/pause *feeding mic audio into*
/// the one long-lived session; `dispose()` is the only thing that actually
/// tears it down, and must only be called once, at the end of the whole
/// conversation (e.g. when the screen is disposed).
///
/// Because the session is never finalized between turns, `DictationTranscriber`'s
/// results are cumulative for the entire app run. `committedLength` tracks how
/// much of that cumulative text has already been reported as a previous
/// turn's final result, so callers only ever see the current turn's own text.
@available(iOS 26.0, *)
actor DictationTranscriberBridge {

    enum BridgeError: Error, LocalizedError {
        case micPermissionDenied
        case speechPermissionDenied
        case unsupportedLocale
        case assetsNotInstalled
        case noCompatibleFormat
        case notReady

        var errorDescription: String? {
            switch self {
            case .micPermissionDenied: return "Microphone permission denied"
            case .speechPermissionDenied: return "Speech recognition permission denied"
            case .unsupportedLocale: return "en-US is not supported on this device"
            case .assetsNotInstalled: return "DictationTranscriber assets are not installed"
            case .noCompatibleFormat: return "No compatible audio format found"
            case .notReady: return "initialize() must succeed before startListening()"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var dictationTranscriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var micFeedTask: Task<Void, Never>?
    private var micBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// True once the underlying engine/analyzer session has been created.
    /// Set once, for the lifetime of the app run (see the type doc above).
    private var sessionStarted = false
    /// True while mic buffers should be fed into the analyzer. False between
    /// turns (e.g. while TTS is speaking), so the app doesn't hear itself —
    /// without needing full AEC/voice-processing.
    private var isFeeding = false

    // DictationTranscriber does not finalize on its own from natural pauses
    // in this pipeline — verified on-device: partial results kept accumulating
    // through several seconds of silence with no isFinal=true ever arriving.
    // So end-of-utterance is detected here instead, the same way the
    // speech_to_text walking-skeleton adapter needed an explicit `pauseFor`.
    private let silenceTimeout: TimeInterval = 2.0
    private var lastActivity = Date.distantPast

    private var fullText = ""
    private var committedLength = 0
    /// Text salvaged from before an internal cumulative-text reset (see
    /// `handleResult`) that hasn't been committed as a turn yet — without
    /// this, a reset mid-utterance silently dropped everything spoken before
    /// it, which is why long utterances stopped reaching TTS after the
    /// shrink-detection fix landed.
    private var carryOverText = ""
    private var feedCount = 0

    private var currentOnPartial: (@Sendable (String) -> Void)?
    private var currentOnFinal: (@Sendable (String) -> Void)?

    // MARK: - initialize()

    func initialize() async -> Bool {
        do {
            print("[DictationTranscriberBridge] initialize: requesting permissions")
            try await requestPermissions()

            guard let supported = await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: "en-US")
            ) else {
                throw BridgeError.unsupportedLocale
            }
            let transcriber = DictationTranscriber(locale: supported, preset: .progressiveLongDictation)
            dictationTranscriber = transcriber

            let preStatus = await AssetInventory.status(forModules: [transcriber])
            print("[DictationTranscriberBridge] asset status before install request: \(preStatus)")

            // On this device en-US is already installed (see the STT finding
            // in CLAUDE.md), so this returns nil (nothing to install) rather
            // than hitting AssetInventory's known fresh-download hang.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                print("[DictationTranscriberBridge] installing assets…")
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw BridgeError.assetsNotInstalled
            }

            print("[DictationTranscriberBridge] initialize: ready")
            return true
        } catch {
            print("[DictationTranscriberBridge] initialize failed: \(error)")
            return false
        }
    }

    private func requestPermissions() async throws {
        let micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard micGranted else { throw BridgeError.micPermissionDenied }

        let speechStatus = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { throw BridgeError.speechPermissionDenied }
    }

    // MARK: - startListening() / stopListening() (per-turn: resume/pause feeding)

    func startListening(
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) async throws {
        currentOnPartial = onPartial
        currentOnFinal = onFinal
        lastActivity = Date()

        guard !sessionStarted else {
            print("[DictationTranscriberBridge] resuming feed (session already running)")
            isFeeding = true
            return
        }
        sessionStarted = true

        guard let transcriber = dictationTranscriber else {
            throw BridgeError.notReady
        }

        let session = AVAudioSession.sharedInstance()
        // .playAndRecord, not .record: this session and this engine stay
        // active continuously for the whole conversation, including while
        // TTS plays through the SAME shared AVAudioSession (see the type doc)
        // — switching categories mid-session would disrupt this already-
        // running input tap. .defaultToSpeaker routes TTS to the speaker
        // instead of the earpiece.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        print("[DictationTranscriberBridge] mic format: \(micFormat)")

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: micFormat
        ) else {
            throw BridgeError.noCompatibleFormat
        }
        print("[DictationTranscriberBridge] analyzer format: \(targetFormat)")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: targetFormat)
        self.analyzer = analyzer
        self.analyzerFormat = targetFormat

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = inputCont
        try await analyzer.start(inputSequence: inputStream)

        consumerTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.handleResult(String(result.text.characters))
                }
            } catch {
                print("[DictationTranscriberBridge] results stream ended with error: \(error)")
            }
        }

        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                await self.checkSilenceTimeout()
            }
        }

        isFeeding = true

        // Buffers are hard off to this stream directly from the real-time
        // audio thread (MicBufferRelay.yield is a plain, non-actor-isolated
        // call), and a single long-lived task drains it into feed(). This
        // matters: the previous version spawned a brand-new `Task { await
        // self.feed(copy) }` per buffer (dozens per second, for the whole
        // app run). Under sustained load those tasks piled up faster than
        // the actor could drain them, and the always-queued-behind-them
        // watchdog task got starved — silence timeouts stopped firing after
        // a few minutes even though audio was still being fed (confirmed
        // on-device: `feed heartbeat` kept climbing with zero commits).
        // `.bufferingNewest(4)` bounds the queue and drops stale audio
        // instead of piling up if the actor ever falls behind, which is the
        // right tradeoff for real-time audio.
        let (micStream, micCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        micBufferContinuation = micCont
        let relay = MicBufferRelay(continuation: micCont)

        micFeedTask = Task { [weak self] in
            for await buffer in micStream {
                await self?.feed(buffer)
            }
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            relay.yield(copy)
        }

        engine.prepare()
        try engine.start()
        print("[DictationTranscriberBridge] session started")
    }

    /// Text for the turn in progress: whatever's new since the last turn was
    /// committed (see `committedLength`), plus anything salvaged from before
    /// an internal reset (see `carryOverText`).
    private func currentUtteranceText() -> String {
        let newPart: String
        if committedLength < fullText.count {
            let start = fullText.index(fullText.startIndex, offsetBy: committedLength)
            newPart = String(fullText[start...])
        } else {
            newPart = ""
        }
        if carryOverText.isEmpty { return newPart }
        if newPart.isEmpty { return carryOverText }
        return carryOverText + " " + newPart
    }

    private func handleResult(_ text: String) {
        print("[DictationTranscriberBridge] result: \(text)")
        if text.count < committedLength {
            // DictationTranscriber's cumulative text isn't guaranteed
            // monotonically growing — confirmed on-device: after a long
            // utterance it can restart from a short fresh string with no
            // signal other than the length dropping. Without carrying the
            // pre-reset uncommitted text forward, it would just be lost —
            // which is what made long utterances stop reaching TTS after the
            // shrink was first detected (the short post-reset fragment, or
            // even "", replaced everything spoken before it).
            let lost = currentUtteranceText()
            if !lost.isEmpty {
                carryOverText = carryOverText.isEmpty ? lost : carryOverText + " " + lost
            }
            print("[DictationTranscriberBridge] cumulative text shrank (\(committedLength) -> \(text.count)); carrying over \"\(lost)\"")
            committedLength = 0
        }
        fullText = text
        lastActivity = Date()
        guard isFeeding else { return }
        currentOnPartial?(currentUtteranceText())
    }

    /// Fires after `silenceTimeout` of no new results, since
    /// DictationTranscriber doesn't finalize turns on its own here.
    private func checkSilenceTimeout() {
        guard isFeeding else { return }
        let pending = currentUtteranceText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty else { return }
        guard Date().timeIntervalSince(lastActivity) > silenceTimeout else { return }

        print("[DictationTranscriberBridge] silence timeout -> committing turn: \(pending)")
        commitCurrentTurn()
    }

    private func commitCurrentTurn() {
        let text = currentUtteranceText()
        committedLength = fullText.count
        carryOverText = ""
        lastActivity = Date()
        currentOnFinal?(text)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard isFeeding else { return }
        guard let continuation = inputContinuation, let target = analyzerFormat else {
            print("[DictationTranscriberBridge] feed dropped: session not running")
            return
        }

        let converted: AVAudioPCMBuffer
        if buffer.format == target {
            converted = buffer
        } else {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
                print("[DictationTranscriberBridge] created converter \(buffer.format) -> \(target)")
            }
            guard let converter else {
                print("[DictationTranscriberBridge] feed dropped: could not create converter")
                return
            }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                print("[DictationTranscriberBridge] feed dropped: could not allocate output buffer")
                return
            }

            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else {
                print("[DictationTranscriberBridge] feed dropped: conversion failed (\(error?.localizedDescription ?? "empty output"))")
                return
            }
            converted = out
        }

        continuation.yield(AnalyzerInput(buffer: converted))
        feedCount += 1
        if feedCount % 100 == 0 {
            print("[DictationTranscriberBridge] feed heartbeat: \(feedCount) buffers yielded so far")
        }
    }

    /// Pauses feeding mic audio into the still-running session — used
    /// between turns while TTS plays. Does NOT tear anything down; see the
    /// type doc for why the session itself stays alive for the whole run.
    func stopListening() async {
        print("[DictationTranscriberBridge] pausing feed")
        isFeeding = false
    }

    /// Actually tears the session down. Call only once, when the whole
    /// conversation ends (e.g. the screen is disposed) — never per-turn.
    func dispose() async {
        guard sessionStarted else { return }
        sessionStarted = false
        isFeeding = false

        watchdogTask?.cancel()
        watchdogTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micBufferContinuation?.finish()
        micBufferContinuation = nil
        await micFeedTask?.value
        micFeedTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await consumerTask?.value
        consumerTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        analyzer = nil
        dictationTranscriber = nil
        analyzerFormat = nil
    }
}

/// Lets the real-time audio tap hand buffers to the actor's mic stream
/// without itself being actor-isolated — `AsyncStream.Continuation.yield`
/// is a plain, thread-safe call, so this needs no `await` and can run
/// directly on the audio thread.
private final class MicBufferRelay: @unchecked Sendable {
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    init(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(buffer)
    }
}

extension AVAudioPCMBuffer {
    /// The tap's buffer is reused after the callback returns, so a copy must
    /// be taken before handing it across the actor boundary.
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

/// Buffers produced by `deepCopy()` are exclusively owned by the caller, so
/// sending them across the actor boundary is safe despite the SDK not
/// marking `AVAudioPCMBuffer` `Sendable`.
extension AVAudioPCMBuffer: @unchecked Sendable {}
