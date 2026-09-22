import 'package:flutter/services.dart';

import '../../ports/stt_port.dart';

/// [SttPort] backed by a native `DictationTranscriber` (iOS 26 `Speech`/
/// `SpeechAnalyzer` framework) bridge (see `ios/Runner/AppDelegate.swift`),
/// replacing the walking-skeleton `speech_to_text` plugin adapter.
///
/// See `.claude/specs/dictation-transcriber-stt-bridge.md` and the STT
/// finding in `.claude/CLAUDE.md` for why `DictationTranscriber` (not
/// `SpeechTranscriber` or a cloud STT) is the adopted choice.
class DictationTranscriberStt implements SttPort {
  DictationTranscriberStt() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const _channel = MethodChannel('voice_loop/stt');

  void Function(String text)? _onPartialResult;
  void Function(String text)? _onFinalResult;

  Future<void> _handleMethodCall(MethodCall call) async {
    final text = (call.arguments as Map?)?['text'] as String? ?? '';
    switch (call.method) {
      case 'onPartialResult':
        _onPartialResult?.call(text);
      case 'onFinalResult':
        _onFinalResult?.call(text);
    }
  }

  @override
  Future<bool> initialize() async {
    final available = await _channel.invokeMethod<bool>('initialize');
    return available ?? false;
  }

  @override
  Future<void> startListening({
    required void Function(String text) onPartialResult,
    required void Function(String text) onFinalResult,
  }) async {
    _onPartialResult = onPartialResult;
    _onFinalResult = onFinalResult;
    await _channel.invokeMethod('startListening');
  }

  @override
  Future<void> stopListening() => _channel.invokeMethod('stopListening');

  @override
  Future<void> dispose() => _channel.invokeMethod('dispose');
}
