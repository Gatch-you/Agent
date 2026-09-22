# DictationTranscriber STT bridge

**Status:** Draft

## Context

The walking skeleton (`.claude/specs/voice-loop-walking-skeleton.md`) uses the `speech_to_text` plugin (`SFSpeechRecognizer`-backed) for STT, as a deliberate placeholder. Design doc §13 and `CLAUDE.md`'s STT finding settled on `DictationTranscriber` (iOS 26 `Speech`/`SpeechAnalyzer` framework) as the adopted, final STT choice for this personal-use app — verified working end-to-end in the native `investigation_docs/` (VoiceLoopLab) prototype, including the fresh-locale-download bug that doesn't matter here because English assets are already installed on the one device this runs on.

This feature replaces the walking-skeleton adapter with the real thing: a Dart↔Swift platform-channel adapter, `DictationTranscriberStt`, implementing the existing `SttPort` interface (`lib/ports/stt_port.dart`) so `voice_loop_screen.dart` needs no changes. The native side ports the proven logic from `investigation_docs/Sources/Transcriber.swift` (asset installation via `AssetInventory`, `DictationTranscriber` with preset `.progressiveLongDictation`, the `SpeechAnalyzer` prepare/start/feed/finish lifecycle) and `AudioEngineHost.swift` (mic capture), simplified: this app's state machine never listens and speaks at the same time (STT is stopped before TTS plays and restarted after), so none of VoiceLoopLab's AEC/voice-processing/barge-in machinery is needed here — a plain `AVAudioEngine` input tap is enough.

Target: physical iPhone only (same device as VoiceLoopLab), matching the personal-use STT decision. `speech_to_text` and its adapter stay in the codebase until this is verified working on-device, then get removed in the same PR (see Out of scope).

## Requirements

- `lib/adapters/stt/dictation_transcriber_stt.dart` implements `SttPort`, communicating with native Swift over a `MethodChannel` named `voice_loop/stt` (mirroring the existing `voice_loop/tts` bridge's pattern in `ios/Runner/AppDelegate.swift`).
- `initialize()`: native side requests microphone (`AVAudioApplication.requestRecordPermission`) and speech-recognition (`SFSpeechRecognizer.requestAuthorization`, same permission surface `DictationTranscriber` sits on) authorization, checks/install `DictationTranscriber` assets for `en-US` via `AssetInventory` (mirroring `Transcriber.installAssets`), and prepares the `SpeechAnalyzer`. Returns `true` only if all of that succeeds.
- `startListening(onPartialResult, onFinalResult)`: native side sets `AVAudioSession` category to `.record` (no voice processing — STT/TTS never run concurrently, see Context), starts the `AVAudioEngine` input tap, feeds buffers into the prepared `DictationTranscriber`/`SpeechAnalyzer` (converting format if needed, per `Transcriber.feed`), and streams results back to Dart by invoking `onPartialResult`/`onFinalResult` methods on the same `MethodChannel`, matching `Transcriber.Update(text, isFinal)`.
- `stopListening()`: native side stops the tap, then finalizes in VoiceLoopLab's proven order (tap stop → finish input → `finalizeAndFinishThroughEndOfInput()` → await the result consumer) so the last word isn't dropped.
- `dispose()`: full teardown (tap, engine, analyzer, channel handler).
- If `initialize()` returns `false` (permission denied, assets not installed, unsupported device), the UI's existing "Speech recognition is not available on this device" path (already in `voice_loop_screen.dart`) handles it — no new UI needed.

## Acceptance criteria

Unit-testable (Dart side, via `MethodChannel.setMockMethodCallHandler` — no device needed):

- [ ] Given `initialize()` is called, when the native side responds `true`, then `initialize()` resolves to `true`.
- [ ] Given `initialize()` is called, when the native side responds `false`, then `initialize()` resolves to `false`.
- [ ] Given `startListening(...)` is called, then the adapter invokes the native `startListening` method (no arguments needed beyond the channel call itself).
- [ ] Given a listening session is active, when native invokes `onPartialResult` with text `T`, then the `onPartialResult` callback passed to `startListening` is called with `T`.
- [ ] Given a listening session is active, when native invokes `onFinalResult` with text `T`, then the `onFinalResult` callback passed to `startListening` is called with `T`.
- [ ] Given `stopListening()` is called, then the adapter invokes the native `stopListening` method.
- [ ] Given `dispose()` is called, then the adapter invokes the native `dispose` method.

Manual, on-device only (native Swift/Speech-framework behavior can't run under `flutter test`):

- [ ] On the physical iPhone, `initialize()` completes `true` without hanging (English assets already installed, per the STT finding).
- [ ] Speaking English produces live partial transcripts and a final transcript matching what was said, end-to-end through the real UI (mirroring VoiceLoopLab's verified self-test and live-mic results).
- [ ] The full voice loop (listen → recognize → echo via TTS → listen again) still works with this adapter swapped in, with no regressions from the walking-skeleton behavior.

## Out of scope

- AEC, voice processing, and barge-in (design doc's barge-in work stays in VoiceLoopLab's findings; this app's state machine never listens while speaking, so it isn't needed here).
- Supporting any locale other than `en-US`, or handling the fresh-locale-download bug (out of scope per the personal-use STT decision in `CLAUDE.md`).
- Android and web targets — iOS physical device only, matching the walking skeleton and the DictationTranscriber decision.
- Removing `speech_to_text` from `pubspec.yaml` and deleting `lib/adapters/stt/speech_to_text_stt.dart` *before* the new adapter is verified working on-device — keep both side by side until then, remove both in the same PR once verified (don't leave dead code after that point).
- Any change to `lib/domain/voice_loop_state.dart`, `lib/ports/stt_port.dart`, or `voice_loop_screen.dart` — this is purely an adapter swap.

## Open questions

- None currently.

## Implementation

<!-- Filled in once Status is Implemented: which source/test files satisfy each acceptance criterion. -->
