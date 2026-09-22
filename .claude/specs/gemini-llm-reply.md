# Gemini LLM reply (real conversation responses)

**Status:** Implemented

## Context

The voice loop can currently listen and speak, but `voice_loop_screen.dart`'s `thinking` phase is a stand-in: it waits a fixed 600ms and then echoes the user's own words back via `ReplyReady(userText)` (see the comment above that line, and `.claude/CLAUDE.md`'s domain bullet: "`thinking` is currently just a short synthetic delay standing in for real LLM latency"). This feature replaces that echo with a real LLM-generated conversational reply, making `VoiceLoopPhase.thinking` do genuine work for the first time.

Per `.claude/CLAUDE.md`'s technology choices and the user's own scoping decisions this session:
- **Provider: Google Gemini, flash-class model** (`gemini-2.5-flash`) — chosen for speed and low cost, matching the app's Phase 1 needs ("モデルの性能はそこまでのものを要求しません。速度が速いもの、コストが安いものとなるとgemini-flashがいいですかね？"). Called via plain HTTP REST (`generativelanguage.googleapis.com`), no SDK needed.
- **API key handling: build-time `--dart-define`, not secure storage yet.** The user explicitly chose the simple approach for this pass ("今回は簡易方式（--dart-define）で進める"), deferring `flutter_secure_storage`-based first-launch onboarding (`CLAUDE.md`'s "API keys ... entered by the user on first launch") to a later feature. The key is read via `String.fromEnvironment('GEMINI_API_KEY')` and supplied at `flutter run`/`flutter build` time via `--dart-define=GEMINI_API_KEY=...` or `--dart-define-from-file` pointing at a gitignored local file — never committed or hardcoded.
- **`LlmPort` carries a `tools` param from day one**, always empty in phase 1, per `CLAUDE.md`'s Phase 2 prep note: "cheap now, expensive to retrofit into a streaming implementation later," and conversation mode must never be given tools (hard separation from a future device-control mode).

This is a vertical slice, not the full design-doc `CascadeSession`/`ConversationSessionPort` abstraction (design doc §01 principle 3, "one swap point") — that composed-session abstraction is still target (see `CLAUDE.md`'s `lib/adapters/` bullet) and is deliberately deferred to a later task; this feature wires `LlmPort` directly into `voice_loop_screen.dart` in the same place the echo used to live, matching how `SttPort`/`TtsPort` were each wired directly before any session abstraction existed.

## Requirements

- `lib/ports/llm_port.dart`: an abstract `LlmPort` with `Future<String> reply(List<VoiceLoopMessage> history, {List<LlmTool> tools = const []})`, plus a placeholder `LlmTool` marker class (empty for now — no tool shape exists yet).
- `lib/adapters/llm/gemini_llm.dart`: `GeminiLlm implements LlmPort`, calling the Gemini `generateContent` REST endpoint with the given API key and an injectable `http.Client` (for testability), sending `history` as `contents` (mapping `MessageRole.user`/`.assistant` to Gemini's `user`/`model` roles) plus a fixed `systemInstruction` establishing the assistant as a friendly English-conversation-practice partner (short, natural replies; gentle correction only when it doesn't derail the flow — the app's actual Phase 1 purpose per `CLAUDE.md`'s Vision section, not a generic chatbot).
- Non-200 responses or a missing/empty reply text raise a `LlmException` (defined alongside `GeminiLlm`) rather than returning a blank string.
- `voice_loop_screen.dart`: the `thinking`-phase block calls `widget.llm.reply(_state.messages)` instead of echoing; on any thrown error, it falls back to a short fixed apologetic reply (e.g. "Sorry, I'm having trouble responding right now.") rather than leaving the loop stuck in `thinking` forever. `VoiceLoopScreen` gains a `required this.llm` constructor parameter.
- `main.dart` wires `GeminiLlm(apiKey: const String.fromEnvironment('GEMINI_API_KEY'))` in.

## Acceptance criteria

- [ ] Given a conversation history, when `GeminiLlm.reply` is called, then it POSTs to the Gemini `generateContent` endpoint with the API key in the query string, the history mapped to `contents` with correct role names, and the fixed system instruction attached.
- [ ] Given a 200 response with a candidate reply, when `GeminiLlm.reply` resolves, then it returns the candidate's text, trimmed.
- [ ] Given a non-200 response, when `GeminiLlm.reply` is called, then it throws `LlmException`.
- [ ] Given a 200 response with no candidates/empty text, when `GeminiLlm.reply` is called, then it throws `LlmException`.
- [ ] Given the LLM call throws, when the screen's `thinking`-phase handler runs, then it still transitions to `speaking` with a fallback apologetic message (verified by inspecting `voice_loop_screen.dart`'s try/catch — not separately unit-tested, since the screen has no existing test harness for its STT/TTS platform-channel dependencies either; see Out of scope).

## Out of scope

- The full `CascadeSession`/`ConversationSessionPort` swap-point abstraction (design doc §01 principle 3) — deferred to a later task, per the Context section above.
- `flutter_secure_storage`-based API key onboarding — deferred; `--dart-define` is an explicitly agreed, temporary measure for this pass.
- Streaming responses (`generateContent` is used, not `streamGenerateContent`) — the existing loop already waits for one full LLM reply before speaking, matching the current speak-the-whole-reply-as-one-unit granularity (`.claude/specs/kokoro-tts-bridge.md`'s own out-of-scope note on streaming TTS).
- Widget/integration tests of `voice_loop_screen.dart` — it has no existing test harness (its `SttPort`/`TtsPort` dependencies are real platform-channel adapters with no fakes yet); only `GeminiLlm` itself is unit-tested, via an injected mock `http.Client`.
- Conversation history compression/`contextPolicy` (design doc's 3-layer compression) — the full, unpruned `_state.messages` list is sent every turn for now; fine at Phase 1's conversation lengths.

## Open questions

- None currently.

## Implementation

Unit-tested (no on-device verification needed for this pass — see Open questions below for the one thing that does still need it):

- `lib/ports/llm_port.dart` — `LlmPort` + placeholder `LlmTool`.
- `lib/adapters/llm/gemini_llm.dart` — `GeminiLlm` (REST call to Gemini `generateContent`, injectable `http.Client`) + `LlmException`.
- `test/adapters/llm/gemini_llm_test.dart` — 4 tests covering all four acceptance criteria that don't require the screen (request shape/role-mapping/system-instruction, successful parse+trim, non-200 → `LlmException`, empty-candidates → `LlmException`).
- `lib/app/voice_loop_screen.dart` — `thinking`-phase handler now calls `widget.llm.reply(_state.messages)` with a try/catch fallback to a fixed apologetic message; `VoiceLoopScreen` gained a `required this.llm` parameter.
- `lib/main.dart` — wires `GeminiLlm(apiKey: const String.fromEnvironment('GEMINI_API_KEY'))` in; the key is supplied via `flutter run --dart-define=GEMINI_API_KEY=...` or `flutter run --dart-define-from-file=.env.json` with a gitignored `client/.env.json` (`{"GEMINI_API_KEY": "..."}`) — root `.gitignore` updated accordingly.
- `pubspec.yaml` — added `http: ^1.2.0` (pure Dart, no native code, no CocoaPods/SPM implications).

Not yet verified on-device: an empty/invalid API key means every reply falls back to the fixed apologetic message rather than erroring loudly, so this needs a real run with a real key to confirm the happy path actually produces a sensible spoken reply, not just that the fallback path works. That's the next step once the user has a Gemini API key ready to supply.
