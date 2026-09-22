# Conversation screen visual design

**Status:** Implemented

## Context

`lib/app/voice_loop_screen.dart` is currently the walking skeleton's minimal debug UI (a phase badge, two plain text blocks, a `FloatingActionButton`) — never intended as the real screen, per `.claude/specs/voice-loop-walking-skeleton.md`. `design/conversation.html` + `design/tokens.css` are an approved, standalone HTML/CSS mockup of the real conversation screen: a dark, iOS-native-styled chat UI with an ambient animated glow, a scrolling message list of chat bubbles, a live-transcript preview while listening, and a bottom control area with a state label and an animated mic button. This feature reproduces that mockup in Flutter, replacing the walking-skeleton UI.

The mockup's JS drives a demo state machine with 4 phases (`idle → listening → thinking → speaking → listening...`) and a message list, which the current `VoiceLoopState` doesn't have (it only tracks `phase` — `idle`/`listening`/`speaking`, no `thinking` — plus a single `liveTranscript`/`finalTranscript` pair, no history). The domain layer needs extending to match before the UI can be wired to it. There is still no LLM (`CascadeSession` isn't built yet — see `CLAUDE.md`'s "Planned architecture"), so `thinking` here is a short, fixed synthetic delay standing in for future LLM latency, and the "reply" is still just an echo of the user's own recognized text, exactly as in the walking skeleton — only the phase shape and the visible history are new.

No on-device or simulator verification for this pass (the user is unavailable) — this PR is verified by `flutter test`/`flutter analyze` plus visual review by the user afterward, not a live run.

## Requirements

- `VoiceLoopPhase` gains a `thinking` value: `idle → listening → thinking → speaking → listening → ...`.
- `VoiceLoopState` replaces its single `finalTranscript` string with an ordered list of messages (`role`: user or assistant, `text`), so the UI can render full conversation history, not just the latest turn.
- Reducer behavior:
  - `listening` + non-empty `FinalResult(text)` → phase `thinking`, appends a **user** message with `text`, clears `liveTranscript`.
  - `listening` + empty/whitespace `FinalResult` → unchanged (already true, must still hold).
  - `thinking` + a new `ReplyReady(text)` event → phase `speaking`, appends an **assistant** message with `text`.
  - `speaking` + `TtsFinished` → phase `listening` (unchanged).
  - `StartRequested` is a no-op in `listening`, `thinking`, and `speaking` (already true for `listening`/`speaking`; extend to `thinking`).
  - `StopRequested` → phase `idle`, `liveTranscript` cleared — but **message history is preserved** (this is a behavior change: the walking skeleton's `StopRequested` reset to a totally fresh `VoiceLoopState()`, which would have wiped the conversation).
- `voice_loop_screen.dart`'s flow: on `FinalResult`, stop STT, wait a short fixed delay (standing in for LLM latency), dispatch `ReplyReady` with the same text (echo), then speak it via TTS as before.
- Visual reproduction of `design/conversation.html` using `design/tokens.css`'s values directly (as named Dart constants, not re-guessed colors/spacing):
  - Dark background, animated ambient glow (2-3 soft blurred colored circles drifting slowly behind the content via `AnimationController`s), intensified slightly during `listening`/`speaking`.
  - Nav bar: "English Practice" title, a session-duration subtitle (elapsed time since the screen opened, ticking), a circular history icon button (no navigation behind it yet — out of scope).
  - Scrollable message list: assistant bubbles left-aligned/grey with a rounded-rect shape (small corner radius on the bottom-left), user bubbles right-aligned/accent-blue (small corner radius on the bottom-right). Each assistant bubble has an adjacent small circular "play" button that calls `TtsPort.speak` for that bubble's text and swaps to an animated equalizer icon while playing; only one bubble plays at a time.
  - Live-transcript line: italic, right-aligned, secondary-label color, with a blinking caret, visible only while `liveTranscript` is non-empty (i.e., effectively only during `listening`).
  - Control area: a state label (small colored dot + text — "Tap to start" / "Listening…" / "Thinking…" / "Speaking…"), a circular mic button (accent-blue background while listening, dimmed/non-interactive while thinking, danger-red with a stop icon while speaking, neutral otherwise) with a pulsing expanding-ring animation while listening/speaking, and a hint line below it.
  - Tapping the mic while `thinking` does nothing (button visually disabled).

## Acceptance criteria

Unit-testable (pure domain, `lib/domain/voice_loop_state.dart`) — all pass (`flutter test`, 11 tests):

- [x] Given phase `listening`, when `FinalResult("hello")` arrives, then phase becomes `thinking`, `messages` gains one entry `(role: user, text: "hello")`, and `liveTranscript` clears.
- [x] Given phase `listening`, when `FinalResult("   ")` (blank) arrives, then phase stays `listening` and `messages` is unchanged.
- [x] Given phase `thinking`, when `ReplyReady("hi there")` arrives, then phase becomes `speaking` and `messages` gains one entry `(role: assistant, text: "hi there")`, appended after any existing messages.
- [x] Given phase `speaking`, when `TtsFinished` arrives, then phase becomes `listening`.
- [x] Given phase `thinking`, when `StartRequested` arrives, then state is unchanged (no-op).
- [x] Given a non-empty `messages` list in any phase, when `StopRequested` arrives, then phase becomes `idle`, `liveTranscript` clears, and `messages` is unchanged (preserved).
- [x] (Regression) All acceptance criteria from `.claude/specs/voice-loop-walking-skeleton.md` that still apply (idle/listening/speaking transitions, startRequested no-ops) continue to pass under the new phase/message shape.

Not unit-tested (visual/animation layer — pending the user's own visual review, not automated):

- The screen's visual match to `design/conversation.html` (colors, spacing, bubble shapes, glow animation, mic ring pulse, equalizer icon). `flutter analyze` is clean and a `flutter run -d chrome` smoke launch showed no runtime exceptions/layout overflows, but this has **not** been visually compared against the mockup or run on iOS (device/simulator) — the user was unavailable for this pass, see Out of scope.

## Out of scope

- Wiring a real LLM — `ReplyReady` still carries an echo of the user's own text, exactly as the walking skeleton did. `CascadeSession`/`LlmPort` are still not built.
- The history icon button's actual navigation/screen — it's a visual placeholder only, matching the mockup's own "not built in this pass" comment.
- Persisting messages across app restarts (`ConversationRepository` isn't built yet) — history lives only in in-memory `VoiceLoopState` for this screen's lifetime.
- On-device/simulator verification — the user is unavailable for this pass; verified by `flutter test`/`flutter analyze` and later visual review only.
- Any change to `lib/ports/stt_port.dart`, `lib/ports/tts_port.dart`, or the native STT/TTS bridges — this is a UI + domain-shape change only.
- Barge-in (interrupting `speaking` by talking) — the mockup's mic tap-to-interrupt is reproduced (tapping during `listening`/`speaking` still stops), but voice-triggered barge-in is not.

## Open questions

- None currently — the "thinking" delay duration and exact echo behavior were resolved by choosing to keep it minimal (short fixed delay, plain echo) since no LLM exists yet; this can change with no interface impact once `CascadeSession` lands.

## Implementation

Verified via `flutter test` (11 domain tests, all green) and `flutter analyze` (clean); a `flutter run -d chrome` launch confirmed no runtime exceptions on first paint. **Not yet verified on iOS (device/simulator) or visually compared against the mockup** — the user was unavailable for this pass and asked for the PR to be opened without that step; please review visually before merging.

- `lib/domain/voice_loop_state.dart` + `test/domain/voice_loop_state_test.dart` — `VoiceLoopPhase.thinking`, `VoiceLoopMessage`/`MessageRole`, `ReplyReady` event, and the updated reducer (all acceptance criteria above).
- `lib/app/theme/voice_loop_tokens.dart` — `design/tokens.css` ported to Dart constants (`VoiceLoopColors`, `VoiceLoopSpacing`, `VoiceLoopRadius`, `VoiceLoopTextStyles`, `voiceLoopEaseStandard`).
- `lib/app/widgets/ambient_glow.dart` — the animated background glow blobs.
- `lib/app/widgets/message_bubble.dart` — `MessageBubble` (chat bubble + entrance animation + play button), `ThinkingBubble` (three-dot indicator).
- `lib/app/widgets/voice_mic_button.dart` — `VoiceMicButton`, the circular mic/stop button with the pulsing-ring animation.
- `lib/app/voice_loop_screen.dart` — rewritten: nav bar, message list, live-transcript line, control area, and the `listening → thinking → speaking` flow (with the synthetic thinking delay and message-list wiring).

Known simplifications, both forced by "no `TtsPort`/`SttPort` changes" being out of scope:
- The `TtsPort` interface has no `stop()`, so replaying an assistant bubble's audio can't truly interrupt another one already playing. The screen ignores taps on a different bubble's play button while one is already marked playing (rather than risking two overlapping/queued native utterances), and tapping the currently-playing bubble again only clears the visual indicator without stopping the underlying audio.
- `mix-blend-mode: screen` from the CSS isn't reproduced as a true blend mode — on the mockup's near-black background it's visually equivalent to plain alpha compositing, which is what the Flutter glow blobs use.
