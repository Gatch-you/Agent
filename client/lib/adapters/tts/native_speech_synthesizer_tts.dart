import 'package:flutter/services.dart';

import '../../ports/tts_port.dart';

/// [TtsPort] backed by a small custom platform channel to `AVSpeechSynthesizer`
/// (see `ios/Runner/AppDelegate.swift`), instead of the `flutter_tts` plugin.
///
/// `flutter_tts` ships no `Package.swift`, so keeping it would force CocoaPods
/// back into the build even with Swift Package Manager enabled. This bridge
/// uses only AVFoundation (part of the OS SDK), so it needs neither CocoaPods
/// nor SPM — and it previews the shape of the real Kokoro-82M platform
/// channel planned for design doc §09.
class NativeSpeechSynthesizerTts implements TtsPort {
  NativeSpeechSynthesizerTts() {
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
