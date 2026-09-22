# Voice loop walking skeleton (Flutter)

**Status:** Implemented

## Context

`client/` was the unmodified `flutter create` counter demo before this spec. Per the design doc's §12 implementation order, the first real milestone is "voice loop alone" — before wiring the custom native `DictationTranscriber`/Kokoro platform channels (design doc §13, adopted but not yet bridged into Flutter), we wanted a minimal, visible walking skeleton to prove the round trip end-to-end and get the state-machine shape right. There is no LLM yet (phase 1 still hasn't reached `CascadeSession`), so this screen simply echoes back whatever it transcribes via TTS — the point is to visualize that STT input and TTS output both work, not to converse.

Two decisions changed during implementation, both driven by the user, both recorded here so the reasoning isn't lost:

- **TTS is a custom native bridge, not `flutter_tts`.** The original plan was `speech_to_text` + `flutter_tts`, both off-the-shelf plugins. Building for iOS surfaced that `flutter_tts` ships no `Package.swift`, so keeping it would force CocoaPods back into the build even with Swift Package Manager enabled — and CocoaPods is being sunset by Flutter, so the user asked to avoid installing it rather than work around it. `speech_to_text` already ships a `Package.swift` and needed no change. TTS was replaced with a minimal `AVSpeechSynthesizer` platform channel (`ios/Runner/AppDelegate.swift` + `lib/adapters/tts/native_speech_synthesizer_tts.dart`), which needs neither CocoaPods nor a third-party SPM package — and previews the shape of the real Kokoro-82M bridge planned for §09.
- **Target platform is the physical iPhone, not macOS/Chrome.** macOS turned out to hit the same CocoaPods requirement as iOS (same `flutter_tts` gap), and the iOS Simulator's microphone path needed enough extra macOS-side permission wrangling (Simulator's mic entry under Privacy & Security, Local Network for the device tunnel) that the user chose to verify on the real device (`yuto の iPhone`, the same iPhone 16e used for VoiceLoopLab) over USB instead.

## Requirements

- A single screen shows: a start/stop mic control, the current state (`idle` / `listening` / `speaking`), the live (partial) transcript, and the last finalized transcript.
- Tapping start begins STT listening; tapping stop ends the session and returns to `idle`.
- While listening, partial STT results update the visible transcript live.
- When STT produces a non-empty final result, the app speaks it back via TTS (echo) and visually shows `speaking` state while doing so.
- An empty/whitespace-only final result does not trigger TTS and does not change state.
- When TTS playback finishes, state returns to `listening` (if the session is still active) so the loop can continue without the user tapping start again.
- The state machine itself (`lib/domain/voice_loop_state.dart`) is pure Dart, has no I/O, and is unit-testable without a device, simulator, or plugin.
- Starting an already-active session, or stopping an already-idle session, is a no-op (guards against invalid transitions), mirroring the guard pattern already proven in VoiceLoopLab's `VoiceLoop.swift`.

## Acceptance criteria

- [x] Given state `idle`, when `startRequested`, then state becomes `listening`.
- [x] Given state `listening`, when `partialResult(text)` arrives, then `liveTranscript` becomes `text` and state stays `listening`.
- [x] Given state `listening`, when `finalResult(text)` arrives with non-empty trimmed text, then state becomes `speaking`, `finalTranscript` becomes `text`, and `liveTranscript` clears.
- [x] Given state `listening`, when `finalResult(text)` arrives with empty/whitespace-only text, then state stays `listening` and `finalTranscript` is unchanged.
- [x] Given state `speaking`, when `ttsFinished`, then state becomes `listening`.
- [x] Given any state, when `stopRequested`, then state becomes `idle`, `liveTranscript` and `finalTranscript` clear.
- [x] Given state `idle`, when `stopRequested`, then state stays `idle` (no-op).
- [x] Given state `listening` or `speaking`, when `startRequested`, then state is unchanged (no-op — already active).

## Out of scope

- The custom native `DictationTranscriber` / Kokoro platform-channel bridges (design doc §13) — this milestone uses `speech_to_text` for STT and a minimal custom `AVSpeechSynthesizer` bridge for TTS (see Context — not `flutter_tts`, and not yet `DictationTranscriber`/Kokoro).
- Any response generation (LLM) — TTS echoes the recognized text verbatim, nothing else.
- `Session`/`Turn`/`Message` persistence, `contextPolicy`, `ConversationRepository`.
- Barge-in detection, AEC tuning, or any audio-engine-level work (already de-risked separately in VoiceLoopLab).
- Android and web targets — verified on iOS (physical device) only.
- Error-state UI polish beyond a minimal message (e.g. mic permission denied) — enough to not crash, not a designed empty/error state.

## Open questions

- None — resolved via user confirmation to use standard Flutter plugins for this first milestone (STT), with TTS pivoting to a custom bridge (see Context) once CocoaPods avoidance ruled out `flutter_tts`.

## Implementation

Verified end-to-end on the physical iPhone 16e (`yuto の iPhone`) over USB: live transcript during speech, final transcript + audible TTS echo after a pause, loop continues automatically.

- `lib/domain/voice_loop_state.dart` + `test/domain/voice_loop_state_test.dart` — the pure state machine, all 8 acceptance criteria covered by unit tests (`flutter test` green).
- `lib/ports/stt_port.dart`, `lib/ports/tts_port.dart` — the swap-point interfaces.
- `lib/adapters/stt/speech_to_text_stt.dart` — `speech_to_text` plugin adapter.
- `lib/adapters/tts/native_speech_synthesizer_tts.dart` + `ios/Runner/AppDelegate.swift` — custom `AVSpeechSynthesizer` MethodChannel bridge (`voice_loop/tts`), replacing `flutter_tts`.
- `lib/app/voice_loop_screen.dart` + `lib/main.dart` — the screen and wiring.
- `ios/Runner/Info.plist` — `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription`.
- `ios/Podfile` deleted, `ios/Flutter/{Debug,Release}.xcconfig` Pods includes removed, `flutter config --enable-swift-package-manager` enabled — CocoaPods fully out of the build.
- `ios/Runner.xcodeproj/project.pbxproj` — `DEVELOPMENT_TEAM = S69Y79AKRK`, `CODE_SIGN_STYLE = Automatic` added to the Runner target's Debug/Release/Profile configs, for on-device signing.

Two real bugs found and fixed during on-device verification (both worth remembering, since they're generic Flutter/iOS gotchas, not specific to this app):

1. **STT never finalized.** `speech_to_text`'s `listen()` has no `pauseFor` by default, so it never marks a result final on its own — it just emits partial results forever until something calls `stop()`. This app only called `stop()` in reaction to a final result, which is a deadlock. Fixed by passing `SpeechListenOptions(pauseFor: Duration(seconds: 2))`.
2. **TTS was silent (no error, no sound).** `speech_to_text` leaves `AVAudioSession` in a record-oriented category after listening; `AVSpeechSynthesizer.speak()` doesn't override the active session, so it played into a session not configured for output. Fixed by explicitly setting `AVAudioSession.sharedInstance().setCategory(.playback, ...)` + `setActive(true)` right before `speak()` in the native bridge.
