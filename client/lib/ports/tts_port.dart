/// Text-to-speech port — the one seam between the voice loop and whichever
/// TTS engine backs it. The walking skeleton implementation
/// (`flutter_tts_tts.dart`) uses the `flutter_tts` plugin; a later
/// on-device Kokoro-82M platform-channel adapter (design doc §09) will
/// implement the same interface.
abstract class TtsPort {
  /// Speaks [text], calling [onComplete] once playback finishes.
  Future<void> speak(String text, {required void Function() onComplete});

  Future<void> dispose();
}
