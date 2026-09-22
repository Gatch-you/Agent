import '../domain/voice_loop_state.dart';

/// A tool the LLM could call — a future phase 2 concept (HomeKit/Matter, App
/// Intents, an MCP client; design doc §10–11). Deliberately empty for now:
/// no tool shape exists yet, and phase 1's conversation mode must never be
/// given tools at all (see `.claude/CLAUDE.md`'s Phase 2 prep note — the
/// separation between conversation mode and device-control mode is hard,
/// switched only by explicit UI/wake-word, never inferred). Carried on
/// [LlmPort.reply] from day one anyway, since retrofitting a `tools` param
/// into an already-streaming implementation later would be expensive.
class LlmTool {
  const LlmTool();
}

/// Response-generation port — the one seam between the voice loop and
/// whichever cloud LLM backs it (today: Gemini Flash, see
/// `lib/adapters/llm/gemini_llm.dart`).
abstract class LlmPort {
  /// Generates a reply given the conversation so far. [tools] is always
  /// empty in phase 1.
  Future<String> reply(List<VoiceLoopMessage> history, {List<LlmTool> tools = const []});
}
