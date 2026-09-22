import 'package:client/domain/voice_loop_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceLoopState', () {
    test('idle + startRequested -> listening', () {
      const state = VoiceLoopState();

      final next = state.reduce(const StartRequested());

      expect(next.phase, VoiceLoopPhase.listening);
    });

    test('listening + partialResult -> liveTranscript updates, stays listening', () {
      const state = VoiceLoopState(phase: VoiceLoopPhase.listening);

      final next = state.reduce(const PartialResult('hello wor'));

      expect(next.phase, VoiceLoopPhase.listening);
      expect(next.liveTranscript, 'hello wor');
    });

    test(
      'listening + non-empty finalResult -> speaking, finalTranscript set, liveTranscript cleared',
      () {
        const state = VoiceLoopState(
          phase: VoiceLoopPhase.listening,
          liveTranscript: 'hello wor',
        );

        final next = state.reduce(const FinalResult('hello world'));

        expect(next.phase, VoiceLoopPhase.speaking);
        expect(next.finalTranscript, 'hello world');
        expect(next.liveTranscript, '');
      },
    );

    test(
      'listening + empty/whitespace finalResult -> stays listening, finalTranscript unchanged',
      () {
        const state = VoiceLoopState(
          phase: VoiceLoopPhase.listening,
          finalTranscript: 'previous',
        );

        final next = state.reduce(const FinalResult('   '));

        expect(next.phase, VoiceLoopPhase.listening);
        expect(next.finalTranscript, 'previous');
      },
    );

    test('speaking + ttsFinished -> listening', () {
      const state = VoiceLoopState(phase: VoiceLoopPhase.speaking);

      final next = state.reduce(const TtsFinished());

      expect(next.phase, VoiceLoopPhase.listening);
    });

    test('any state + stopRequested -> idle, transcripts cleared', () {
      const state = VoiceLoopState(
        phase: VoiceLoopPhase.speaking,
        liveTranscript: 'live',
        finalTranscript: 'final',
      );

      final next = state.reduce(const StopRequested());

      expect(next.phase, VoiceLoopPhase.idle);
      expect(next.liveTranscript, '');
      expect(next.finalTranscript, '');
    });

    test('idle + stopRequested -> no-op, stays idle', () {
      const state = VoiceLoopState();

      final next = state.reduce(const StopRequested());

      expect(next.phase, VoiceLoopPhase.idle);
    });

    test('listening + startRequested -> no-op, already active', () {
      const state = VoiceLoopState(
        phase: VoiceLoopPhase.listening,
        liveTranscript: 'in progress',
      );

      final next = state.reduce(const StartRequested());

      expect(next.phase, VoiceLoopPhase.listening);
      expect(next.liveTranscript, 'in progress');
    });

    test('speaking + startRequested -> no-op, already active', () {
      const state = VoiceLoopState(phase: VoiceLoopPhase.speaking);

      final next = state.reduce(const StartRequested());

      expect(next.phase, VoiceLoopPhase.speaking);
    });
  });
}
