/// Speech-to-text port — the one seam between the voice loop UI/domain and
/// whichever STT engine backs it. The walking skeleton implementation
/// (`speech_to_text_stt.dart`) uses the `speech_to_text` plugin; a later
/// `DictationTranscriberStt` platform-channel adapter (design doc §13) will
/// implement the same interface.
abstract class SttPort {
  /// Requests permissions and prepares the engine. Returns false if speech
  /// recognition is unavailable on this device/platform.
  Future<bool> initialize();

  /// Starts listening. [onPartialResult] fires for interim (non-final)
  /// recognition updates, [onFinalResult] once for the finalized utterance.
  Future<void> startListening({
    required void Function(String text) onPartialResult,
    required void Function(String text) onFinalResult,
  });

  Future<void> stopListening();

  Future<void> dispose();
}
