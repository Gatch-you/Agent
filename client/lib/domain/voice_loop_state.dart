/// Pure Dart state machine for the voice loop (idle -> listening -> speaking).
///
/// No I/O here — STT/TTS adapters feed events in and read [VoiceLoopState]
/// back out. This mirrors VoiceLoopLab's `VoiceLoop.swift` state guards
/// (starting twice / stopping when idle are no-ops) so the same shape can be
/// carried into the real `sessionMachine` once the native bridges land.
library;

enum VoiceLoopPhase { idle, listening, speaking }

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

class TtsFinished extends VoiceLoopEvent {
  const TtsFinished();
}

class VoiceLoopState {
  const VoiceLoopState({
    this.phase = VoiceLoopPhase.idle,
    this.liveTranscript = '',
    this.finalTranscript = '',
  });

  final VoiceLoopPhase phase;
  final String liveTranscript;
  final String finalTranscript;

  VoiceLoopState copyWith({
    VoiceLoopPhase? phase,
    String? liveTranscript,
    String? finalTranscript,
  }) {
    return VoiceLoopState(
      phase: phase ?? this.phase,
      liveTranscript: liveTranscript ?? this.liveTranscript,
      finalTranscript: finalTranscript ?? this.finalTranscript,
    );
  }

  VoiceLoopState reduce(VoiceLoopEvent event) {
    if (event is StopRequested) {
      return const VoiceLoopState();
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
            phase: VoiceLoopPhase.speaking,
            finalTranscript: event.text,
            liveTranscript: '',
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
