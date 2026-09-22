import 'package:flutter/material.dart';

import 'adapters/llm/gemini_llm.dart';
import 'adapters/stt/dictation_transcriber_stt.dart';
import 'adapters/tts/kokoro_tts.dart';
import 'app/voice_loop_screen.dart';

// Supplied at build/run time via --dart-define=GEMINI_API_KEY=...
// (or --dart-define-from-file pointing at a gitignored local file) — a
// temporary measure pending flutter_secure_storage-based onboarding, see
// .claude/specs/gemini-llm-reply.md.
const _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

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
      home: VoiceLoopScreen(
        stt: DictationTranscriberStt(),
        tts: KokoroTts(),
        llm: GeminiLlm(apiKey: _geminiApiKey),
      ),
    );
  }
}
