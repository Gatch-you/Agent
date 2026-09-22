/// Pure Dart state machine for the voice loop
/// (idle -> listening -> thinking -> speaking -> listening -> ...).
///
/// No I/O here — STT/TTS adapters feed events in and read [VoiceLoopState]
/// back out. This mirrors VoiceLoopLab's `VoiceLoop.swift` state guards
/// (starting twice / stopping when idle are no-ops) so the same shape can be
/// carried into the real `sessionMachine` once the native bridges land.
///
/// `thinking` is a placeholder for future LLM latency (there's no LLM yet —
/// see `.claude/specs/conversation-screen-visual-design.md`): the caller
/// dispatches [ReplyReady] itself after a short synthetic delay, still
/// carrying an echo of the user's own text.
library;

enum VoiceLoopPhase { idle, listening, thinking, speaking }

enum MessageRole { user, assistant }

/// A single turn in the visible conversation history. Deliberately not
/// named `Message` — that name is reserved for the future persisted
/// `Session`/`Turn`/`Message` domain model (see `CLAUDE.md`); this is
/// purely this screen's in-memory display state.
class VoiceLoopMessage {
  const VoiceLoopMessage({required this.role, required this.text});

  final MessageRole role;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is VoiceLoopMessage && other.role == role && other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  @override
  String toString() => 'VoiceLoopMessage($role, $text)';
}

sealed class VoiceLoopEvent {
  const VoiceLoopEvent();
}

class StartRequested extends VoiceLoopEvent {
  const StartRequested();
}

class StopRequested extends VoiceLoopEvent {
  const StopRequested();
}

class PartialResult extends VoiceLoopEvent {
  const PartialResult(this.text);
  final String text;
}

class FinalResult extends VoiceLoopEvent {
  const FinalResult(this.text);
  final String text;
}

/// Dispatched once a reply is ready to be spoken. Until `CascadeSession`/an
/// `LlmPort` exist, callers dispatch this themselves after a short synthetic
/// delay, with `text` still just an echo of the user's own final result.
class ReplyReady extends VoiceLoopEvent {
  const ReplyReady(this.text);
  final String text;
}

class TtsFinished extends VoiceLoopEvent {
  const TtsFinished();
}

class VoiceLoopState {
  const VoiceLoopState({
    this.phase = VoiceLoopPhase.idle,
    this.liveTranscript = '',
    this.messages = const [],
  });

  final VoiceLoopPhase phase;
  final String liveTranscript;
  final List<VoiceLoopMessage> messages;

  VoiceLoopState copyWith({
    VoiceLoopPhase? phase,
    String? liveTranscript,
    List<VoiceLoopMessage>? messages,
  }) {
    return VoiceLoopState(
      phase: phase ?? this.phase,
      liveTranscript: liveTranscript ?? this.liveTranscript,
      messages: messages ?? this.messages,
    );
  }

  VoiceLoopState reduce(VoiceLoopEvent event) {
    if (event is StopRequested) {
      // Message history is deliberately preserved across a stop — only the
      // in-flight turn (phase, live transcript) resets.
      return copyWith(phase: VoiceLoopPhase.idle, liveTranscript: '');
    }

    switch (phase) {
      case VoiceLoopPhase.idle:
        if (event is StartRequested) {
          return copyWith(phase: VoiceLoopPhase.listening);
        }
        return this;

      case VoiceLoopPhase.listening:
        if (event is PartialResult) {
          return copyWith(liveTranscript: event.text);
        }
        if (event is FinalResult) {
          if (event.text.trim().isEmpty) return this;
          return copyWith(
            phase: VoiceLoopPhase.thinking,
            liveTranscript: '',
            messages: [...messages, VoiceLoopMessage(role: MessageRole.user, text: event.text)],
          );
        }
        return this;

      case VoiceLoopPhase.thinking:
        if (event is ReplyReady) {
          return copyWith(
            phase: VoiceLoopPhase.speaking,
            messages: [
              ...messages,
              VoiceLoopMessage(role: MessageRole.assistant, text: event.text),
            ],
          );
        }
        return this;

      case VoiceLoopPhase.speaking:
        if (event is TtsFinished) {
          return copyWith(phase: VoiceLoopPhase.listening);
        }
        return this;
    }
  }
}
