import 'package:flutter/material.dart';

import 'adapters/stt/dictation_transcriber_stt.dart';
import 'adapters/tts/kokoro_tts.dart';
import 'app/voice_loop_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Loop',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: VoiceLoopScreen(stt: DictationTranscriberStt(), tts: KokoroTts()),
    );
  }
}
