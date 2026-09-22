import 'package:speech_to_text/speech_to_text.dart' as plugin;

import '../../ports/stt_port.dart';

/// [SttPort] backed by the `speech_to_text` plugin (platform-native
/// SFSpeechRecognizer/Android SpeechRecognizer/Web Speech API). This is the
/// walking-skeleton adapter — see the STT finding in `.claude/CLAUDE.md` for
/// why the eventual production adapter bridges to `DictationTranscriber`
/// directly instead.
class SpeechToTextStt implements SttPort {
  final plugin.SpeechToText _speech = plugin.SpeechToText();

  @override
  Future<bool> initialize() => _speech.initialize();

  @override
  Future<void> startListening({
    required void Function(String text) onPartialResult,
    required void Function(String text) onFinalResult,
  }) {
    return _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          onFinalResult(result.recognizedWords);
        } else {
          onPartialResult(result.recognizedWords);
        }
      },
      // Without pauseFor, the plugin never marks a result final on its own —
      // it just keeps emitting partial results until something calls stop(),
      // which here only happens in reaction to a final result. That's a
      // deadlock, and was why nothing ever reached the "speaking" phase.
      listenOptions: plugin.SpeechListenOptions(pauseFor: const Duration(seconds: 2)),
    );
  }

  @override
  Future<void> stopListening() => _speech.stop();

  @override
  Future<void> dispose() => _speech.cancel();
}
