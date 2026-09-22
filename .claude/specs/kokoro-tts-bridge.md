# Kokoro-82M TTS bridge

**Status:** Draft

## Context

The walking-skeleton TTS bridge (`lib/adapters/tts/native_speech_synthesizer_tts.dart` + the `voice_loop/tts` handler in `ios/Runner/AppDelegate.swift`) uses Apple's stock `AVSpeechSynthesizer` — a deliberate placeholder, per `.claude/CLAUDE.md`'s "Planned architecture" (`tts/... migrating the walking-skeleton bridge to on-device Kokoro`). Kokoro-82M's adoption is already confirmed (design doc §09): the listening/quality test passed (`investigation_docs/kokoro_tts_listening_test.ipynb`), and real-device performance is already measured via VoiceLoopLab (warmup-inclusive load 0.86s, RTF mean 0.153/worst 0.188, peak memory 687MB — all within the design doc's pass bar). This feature does the adapter swap: `AVSpeechSynthesizer` → the on-device Kokoro-82M model, via `soniqo/speech-swift`'s `KokoroTTS` package, exactly as already proven in `investigation_docs/Sources/TtsEngine.swift`.

`TtsPort` (`lib/ports/tts_port.dart`) is unchanged — out of scope to touch — so `voice_loop_screen.dart` needs no changes.

**Two integration pieces make this different from a typical adapter swap:**

1. **This bridge owns real audio playback for the first time.** `AVSpeechSynthesizer` handles its own playback internally; Kokoro only returns raw 24kHz mono Float32 samples (via `KokoroTTSModel.synthesize(text:voice:)`), so this bridge needs its own `AVAudioEngine` + `AVAudioPlayerNode` to actually play them, ported from `TtsEngine.swift`/`AudioEngineHost.swift`'s playback pattern in VoiceLoopLab. This new engine must **not** set its own `AVAudioSession` category — `DictationTranscriberBridge.swift`'s persistent `.playAndRecord` session is already active and must keep running continuously through TTS playback (read that file's doc comment before touching audio session code here); this new engine just attaches a player node to the existing session.
2. **`soniqo/speech-swift` is a remote Swift Package**, which VoiceLoopLab added via `xcodegen`'s `project.yml`. This Flutter project's `ios/Runner.xcodeproj` has no `xcodegen` — `project.pbxproj` is hand-maintained (see `DictationTranscriberBridge.swift`'s file-addition entries in it for the precedent of manual surgery on this file). Hand-editing a *remote package reference* by hand is riskier than a single file addition and could corrupt the whole Xcode project, so this uses the Python `pbxproj` library's `XcodeProject.add_package(...)` API (installed in an isolated venv for this session) to add the package safely instead of raw text editing.

The model weights (~318MB, already downloaded and bundled once for VoiceLoopLab at `investigation_docs/Resources/KokoroModel`) get copied into `ios/Runner/Resources/KokoroModel` as a folder reference, loaded offline (`offlineMode: true`) exactly as `TtsEngine.swift` does — no fresh download at runtime. This will make the app/IPA noticeably larger; that's expected, not a regression, matching VoiceLoopLab's already-accepted footprint for this model.

This needs on-device verification (audio quality/behavior can't be judged any other way) — the user is available this time.

## Requirements

- `lib/adapters/tts/kokoro_tts.dart` implements `TtsPort` unchanged, communicating with native Swift over the existing `voice_loop/tts` `MethodChannel` (same channel name/shape as the walking-skeleton bridge, so no Dart-side port change).
- Native side (`ios/Runner/KokoroTtsBridge.swift`, new file, registered in `AppDelegate.swift`'s existing `voice_loop/tts` handler in place of the `AVSpeechSynthesizer` calls):
  - Loads `KokoroTTSModel` once (lazily, on first `speak()` call) from the bundled `Resources/KokoroModel` folder, offline mode, matching `TtsEngine.load()`.
  - `speak(text)`: synthesizes 24kHz mono Float32 samples via `KokoroTTSModel.synthesize(text:voice:)`, plays them through an `AVAudioEngine`/`AVAudioPlayerNode` attached to the *existing* audio session (no category/activation calls here — `DictationTranscriberBridge` already owns that), and invokes the `onComplete` `MethodChannel` callback when playback finishes.
  - `stop()`: stops playback immediately (existing walking-skeleton behavior, `synthesizer.stopSpeaking(at: .immediate)` today — the Kokoro equivalent is stopping the player node).
  - A code comment documents the ANE-bypass fallback (`computeUnits: .cpuAndGPU`) from `TtsEngine.swift`/`speech-swift`'s own docs, for if audio ever sounds broken on a future iOS build — not wired to any UI toggle (no diagnostics panel in this app).
- `ios/Runner.xcodeproj/project.pbxproj` gets a `soniqo/speech-swift` remote package reference (branch `main`, matching VoiceLoopLab's `project.yml`) with product dependencies `KokoroTTS` and `AudioCommon` linked to the `Runner` target, added via the Python `pbxproj` library, not hand-edited.
- `ios/Runner/Resources/KokoroModel/` — the ~318MB of weights, copied from `investigation_docs/Resources/KokoroModel`, added as a folder reference (resources build phase) in the same pbxproj edit.
- The walking-skeleton `NativeSpeechSynthesizerTts`/`AVSpeechSynthesizer` code path is removed once Kokoro is verified working on-device (same "keep both until verified, then remove in the same PR" pattern as the STT bridge spec).

## Acceptance criteria

Manual, on-device only (native audio quality/behavior can't run under `flutter test`) — this feature is almost entirely native audio I/O, so there is little to unit-test; no new Dart-side logic is introduced beyond a thin `MethodChannel` pass-through identical in shape to the existing (already-tested-by-precedent) `NativeSpeechSynthesizerTts`:

- [ ] The app builds and installs on the physical iPhone with the bundled Kokoro model (confirms the SPM package + Resources folder reference were added correctly).
- [ ] Speaking to the app produces a reply spoken back in Kokoro's voice (not Apple's default voice) — audibly distinguishable from the walking-skeleton's `AVSpeechSynthesizer` output.
- [ ] The full voice loop (listen → recognize → echo → Kokoro speaks it → listen again) works end-to-end for several consecutive turns, matching the stability already achieved with the STT bridge (`.claude/specs/dictation-transcriber-stt-bridge.md`) — no audio session conflicts with the persistent STT session.
- [ ] Playback completion is correctly detected (`onComplete` fires once, at the right time) so the loop resumes listening promptly, not late or never.

## Out of scope

- Any change to `lib/ports/tts_port.dart` or `voice_loop_screen.dart` — this is purely an adapter swap.
- Re-verifying the design doc §09 quality/performance findings — already done (listening test + VoiceLoopLab real-device numbers), not repeated here.
- A UI toggle for the ANE-bypass fallback — documented in a code comment only.
- Voice selection UI — a single fixed voice (matching whatever VoiceLoopLab used, e.g. `af_heart`) is fine for now.
- Streaming/chunked synthesis (splitting long replies into sentence-level chunks for lower perceived latency) — out of scope for this pass; `speak()` synthesizes and plays the whole reply as one unit, same granularity as today.

## Open questions

- None currently.

## Implementation

<!-- Filled in once Status is Implemented: which source/test files satisfy each acceptance criterion. -->
