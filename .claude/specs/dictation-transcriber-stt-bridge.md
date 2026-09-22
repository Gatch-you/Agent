# DictationTranscriber STT bridge

**Status:** Implemented

## Context

The walking skeleton (`.claude/specs/voice-loop-walking-skeleton.md`) used the `speech_to_text` plugin (`SFSpeechRecognizer`-backed) for STT, as a deliberate placeholder. Design doc §13 and `CLAUDE.md`'s STT finding settled on `DictationTranscriber` (iOS 26 `Speech`/`SpeechAnalyzer` framework) as the adopted, final STT choice for this personal-use app — verified working end-to-end in the native `investigation_docs/` (VoiceLoopLab) prototype, including the fresh-locale-download bug that doesn't matter here because English assets are already installed on the one device this runs on.

This feature replaces the walking-skeleton adapter with the real thing: a Dart↔Swift platform-channel adapter, `DictationTranscriberStt`, implementing the existing `SttPort` interface (`lib/ports/stt_port.dart`) so `voice_loop_screen.dart` needs no changes.

**The native session design changed significantly from the original plan during on-device testing, and this is the most important thing to understand before touching this code again.** The plan going in was to mirror VoiceLoopLab's per-call shape directly: `startListening()` fully sets up `SpeechAnalyzer`/`DictationTranscriber`/`AVAudioEngine` each turn, `stopListening()` calls `finalizeAndFinishThroughEndOfInput()` and tears it all down, next turn rebuilds it. **That crashed on-device inside the Speech framework's own worker state machine** (`EXC_BREAKPOINT` in `Speech.TranscriberCommon.worker.setter` / `isWorkerUsable`), reproducing consistently after a handful of turns. VoiceLoopLab never exercises a restart-per-turn pattern — it builds one `SpeechAnalyzer` session per whole conversation and only finalizes at the very end — so this is being treated as a real per-turn-restart SDK bug to avoid, not something fixable from the call site.

The fix: **the underlying session is now built exactly once per app run and never torn down between turns.** `startListening()`/`stopListening()` just resume/pause *feeding mic audio into* that one long-lived session; only `dispose()` (screen teardown) actually calls `finalizeAndFinishThroughEndOfInput()`. This has knock-on effects that took three more rounds of on-device debugging to find, all now fixed and worth knowing about:

1. **`DictationTranscriber`'s results never finalize on their own.** Verified on-device: partial results kept accumulating through many seconds of continuous silence with `isFinal` never turning `true`. So turn-boundary detection is done here instead, via a 2-second silence timeout over the incoming partials — the same shape as the `pauseFor` fix the walking skeleton needed for `speech_to_text`.
2. **Spawning a `Task` per audio buffer caused actor-queue starvation.** The first version of the persistent-session bridge fed each mic buffer via `Task { await self.feed(copy) }`. Under sustained use (multiple minutes, dozens of turns) those unstructured tasks piled up on the actor faster than they drained, and the periodic silence-timeout check — itself just another queued task — got starved out entirely: audio kept flowing (`feed heartbeat` logs kept climbing) but turns stopped ever completing. Fixed by handing buffers to a single long-lived consumer task through a bounded `AsyncStream` (`.bufferingNewest(4)`) instead of spawning one task per buffer.
3. **`DictationTranscriber`'s cumulative text isn't guaranteed to only grow.** Since the session is never finalized between turns, its `results` are cumulative across the whole run — turn text is computed as a delta since the last committed length. But the cumulative string can unpredictably *shrink* (observed on-device, e.g. `290 chars → 1 char`, with no other signal). Left unhandled, the delta calculation would get stuck permanently returning `""` once this happened (looked identical to the app just "not responding" mid-turn). Fixed by detecting a length decrease and resetting the commit boundary — but doing *only* that silently dropped everything spoken before an in-utterance reset (long turns stopped reaching TTS). The real fix carries the pre-reset uncommitted text forward and prepends it to whatever comes after, so a reset mid-utterance is invisible to the user.

The native side still ports the proven pieces from `investigation_docs/Sources/Transcriber.swift` (`AssetInventory` asset installation, `DictationTranscriber` with preset `.progressiveLongDictation`, the `SpeechAnalyzer` prepare/start/feed lifecycle) and `AudioEngineHost.swift` (mic capture) — just wired into a persistent-session shape those files never needed. None of VoiceLoopLab's AEC/voice-processing/barge-in machinery is needed: `.playAndRecord` (not `.record`) is used specifically because the session and its `AVAudioEngine` stay alive continuously *including while TTS plays* (switching categories mid-session would disrupt the already-running input tap), but there's still no simultaneous listen-while-speak — mic feeding is simply paused during TTS playback.

Target: physical iPhone only (same device as VoiceLoopLab), matching the personal-use STT decision.

## Requirements

- `lib/adapters/stt/dictation_transcriber_stt.dart` implements `SttPort`, communicating with native Swift over a `MethodChannel` named `voice_loop/stt` (mirroring the existing `voice_loop/tts` bridge's pattern in `ios/Runner/AppDelegate.swift`).
- `initialize()`: native side requests microphone (`AVAudioApplication.requestRecordPermission`) and speech-recognition (`SFSpeechRecognizer.requestAuthorization`, same permission surface `DictationTranscriber` sits on) authorization, and checks/installs `DictationTranscriber` assets for `en-US` via `AssetInventory`. Returns `true` only if all of that succeeds. Does *not* build the `SpeechAnalyzer` session yet (see Context — that's deferred to the first `startListening()` call, once the real hardware audio format is available).
- `startListening(onPartialResult, onFinalResult)`: on the *first* call, builds the persistent session — sets `AVAudioSession` category to `.playAndRecord` with `.defaultToSpeaker`, determines the analyzer's target format from the real mic format, prepares `SpeechAnalyzer`, and starts the `AVAudioEngine` input tap feeding it through a bounded buffer queue. On every call after that, it just resumes feeding mic audio into the already-running session. Results stream back to Dart via `onPartialResult`/`onFinalResult` invoked on the same `MethodChannel`, each carrying only the current turn's own text (see Context for the cumulative-text/carry-over handling behind that).
- `stopListening()`: pauses feeding mic audio into the session (does not tear anything down — see Context for why).
- `dispose()`: the only thing that actually tears the session down — stops the tap, finalizes via `finalizeAndFinishThroughEndOfInput()` in VoiceLoopLab's proven order (tap stop → finish input → finalize → await the result consumer), and releases everything. Must be called exactly once, when the whole conversation ends.
- If `initialize()` returns `false` (permission denied, assets not installed, unsupported device), the UI's existing "Speech recognition is not available on this device" path (already in `voice_loop_screen.dart`) handles it — no new UI needed.
- A 2-second silence timeout (no new partial text) is what marks a turn's end and triggers `onFinalResult`, since `DictationTranscriber` doesn't finalize turns on its own (see Context).

## Acceptance criteria

Unit-testable (Dart side, via `MethodChannel.setMockMethodCallHandler` — no device needed):

- [x] Given `initialize()` is called, when the native side responds `true`, then `initialize()` resolves to `true`.
- [x] Given `initialize()` is called, when the native side responds `false`, then `initialize()` resolves to `false`.
- [x] Given `startListening(...)` is called, then the adapter invokes the native `startListening` method (no arguments needed beyond the channel call itself).
- [x] Given a listening session is active, when native invokes `onPartialResult` with text `T`, then the `onPartialResult` callback passed to `startListening` is called with `T`.
- [x] Given a listening session is active, when native invokes `onFinalResult` with text `T`, then the `onFinalResult` callback passed to `startListening` is called with `T`.
- [x] Given `stopListening()` is called, then the adapter invokes the native `stopListening` method.
- [x] Given `dispose()` is called, then the adapter invokes the native `dispose` method.

Manual, on-device only (native Swift/Speech-framework behavior can't run under `flutter test`) — all verified on the physical iPhone (`yuto の iPhone`, iOS 26.6):

- [x] `initialize()` completes `true` without hanging (English assets already installed, per the STT finding).
- [x] Speaking English produces live partial transcripts and a final transcript matching what was said, end-to-end through the real UI.
- [x] The full voice loop (listen → recognize → echo via TTS → listen again) works with this adapter swapped in.
- [x] The session survives many consecutive turns (20+) and several minutes of continuous use without crashing or freezing — this needed the three fixes described in Context (persistent session, bounded buffer queue, cumulative-text reset + carry-over handling); each was individually reproduced on-device and confirmed fixed before moving to the next.
- [x] A long utterance that spans an internal cumulative-text reset is still spoken back in full by TTS (confirms the carry-over fix, not just the crash fix).

## Out of scope

- AEC, voice processing, and barge-in (design doc's barge-in work stays in VoiceLoopLab's findings; this app's state machine never listens while speaking, so it isn't needed here — mic feeding is paused during TTS instead).
- Supporting any locale other than `en-US`, or handling the fresh-locale-download bug (out of scope per the personal-use STT decision in `CLAUDE.md`).
- Android and web targets — iOS physical device only, matching the walking skeleton and the DictationTranscriber decision.
- Any change to `lib/domain/voice_loop_state.dart`, `lib/ports/stt_port.dart`, or `voice_loop_screen.dart` — this is purely an adapter swap.

## Open questions

- None currently.

## Implementation

Verified end-to-end on the physical iPhone 16e (`yuto の iPhone`) over USB: 20+ consecutive turns, several minutes of continuous use, no crashes, no freezes, long utterances spanning internal resets read back in full.

- `lib/adapters/stt/dictation_transcriber_stt.dart` + `test/adapters/stt/dictation_transcriber_stt_test.dart` — the Dart adapter and its 7 `MethodChannel`-mocked unit tests (all green).
- `ios/Runner/DictationTranscriberBridge.swift` — the native persistent-session actor: asset install, `SpeechAnalyzer`/`DictationTranscriber` lifecycle, silence-timeout turn detection, bounded-queue mic feeding, cumulative-text reset detection + carry-over.
- `ios/Runner/AppDelegate.swift` — the `voice_loop/stt` `MethodChannel` wiring (`initialize`/`startListening`/`stopListening`/`dispose`), guarded by `#available(iOS 26.0, *)`; the `voice_loop/tts` handler's category-switching code was removed here too, since it would have disrupted the now-continuously-running STT engine (see Context).
- `ios/Runner.xcodeproj/project.pbxproj` — `DictationTranscriberBridge.swift` added to the Runner target's file references, group, and Sources build phase (this project doesn't use Xcode's filesystem-synchronized groups, so new files need explicit `pbxproj` entries).
- `lib/main.dart` — wired to `DictationTranscriberStt()` instead of `SpeechToTextStt()`.
- `pubspec.yaml`, `lib/adapters/stt/speech_to_text_stt.dart` (deleted) — `speech_to_text` and its walking-skeleton adapter are fully removed now that the real bridge is verified.

<!-- Filled in once Status is Implemented: which source/test files satisfy each acceptance criterion. -->
