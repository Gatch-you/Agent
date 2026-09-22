import 'package:flutter/services.dart';

import '../../ports/tts_port.dart';

/// [TtsPort] backed by the on-device Kokoro-82M model
/// (`ios/Runner/KokoroTtsBridge.swift`, via `soniqo/speech-swift`'s
/// `KokoroTTS` package), replacing the walking-skeleton's
/// `AVSpeechSynthesizer`-based `NativeSpeechSynthesizerTts`.
///
/// The channel name and method shape (`speak`/`stop`/`onComplete`) are
/// unchanged from the walking-skeleton bridge — only what's behind them on
/// the native side changed — so this class is almost identical to
/// `NativeSpeechSynthesizerTts`. See `.claude/specs/kokoro-tts-bridge.md`.
class KokoroTts implements TtsPort {
  KokoroTts() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const _channel = MethodChannel('voice_loop/tts');

  void Function()? _onComplete;

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onComplete') {
      _onComplete?.call();
    }
  }

  @override
  Future<void> speak(String text, {required void Function() onComplete}) async {
    _onComplete = onComplete;
    await _channel.invokeMethod('speak', {'text': text});
  }

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod('stop');
  }
}
