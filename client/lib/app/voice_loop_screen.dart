import 'package:flutter/material.dart';

import '../domain/voice_loop_state.dart';
import '../ports/stt_port.dart';
import '../ports/tts_port.dart';

/// Walking-skeleton voice loop screen (.claude/specs/voice-loop-walking-skeleton.md).
///
/// Speaks back whatever it hears (no LLM yet) so both the STT input and the
/// TTS output are visible in one place: live transcript while listening,
/// final transcript once recognized, and a phase indicator while it echoes
/// the reply back.
class VoiceLoopScreen extends StatefulWidget {
  const VoiceLoopScreen({super.key, required this.stt, required this.tts});

  final SttPort stt;
  final TtsPort tts;

  @override
  State<VoiceLoopScreen> createState() => _VoiceLoopScreenState();
}

class _VoiceLoopScreenState extends State<VoiceLoopScreen> {
  VoiceLoopState _state = const VoiceLoopState();
  bool? _sttAvailable;

  @override
  void initState() {
    super.initState();
    widget.stt.initialize().then((available) {
      if (!mounted) return;
      setState(() => _sttAvailable = available);
    });
  }

  @override
  void dispose() {
    widget.stt.dispose();
    widget.tts.dispose();
    super.dispose();
  }

  void _onMicPressed() {
    if (_state.phase == VoiceLoopPhase.idle) {
      _start();
    } else {
      _stop();
    }
  }

  Future<void> _start() async {
    setState(() => _state = _state.reduce(const StartRequested()));
    await _listenOnce();
  }

  Future<void> _stop() async {
    setState(() => _state = _state.reduce(const StopRequested()));
    await widget.stt.stopListening();
  }

  Future<void> _listenOnce() async {
    await widget.stt.startListening(
      onPartialResult: (text) {
        if (!mounted) return;
        setState(() => _state = _state.reduce(PartialResult(text)));
      },
      onFinalResult: (text) async {
        if (!mounted) return;
        setState(() => _state = _state.reduce(FinalResult(text)));
        if (_state.phase != VoiceLoopPhase.speaking) return;

        final reply = _state.finalTranscript;
        await widget.stt.stopListening();
        await widget.tts.speak(
          reply,
          onComplete: () {
            if (!mounted) return;
            setState(() => _state = _state.reduce(const TtsFinished()));
            if (_state.phase == VoiceLoopPhase.listening) {
              _listenOnce();
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice loop (walking skeleton)')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PhaseBadge(phase: _state.phase),
            const SizedBox(height: 24),
            const Text('Live (STT input)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              _state.liveTranscript.isEmpty ? '—' : _state.liveTranscript,
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            const Text('Final (TTS output)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              _state.finalTranscript.isEmpty ? '—' : _state.finalTranscript,
              style: const TextStyle(fontSize: 16),
            ),
            if (_sttAvailable == false) ...[
              const SizedBox(height: 24),
              const Text(
                'Speech recognition is not available on this device.',
                style: TextStyle(color: Colors.red),
              ),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        // Only enabled once initialize() has resolved to true. While
        // `_sttAvailable` is still null (initializing) or false
        // (unavailable), pressing this would otherwise hit the plugin
        // before it's ready and throw SpeechToTextNotInitializedException.
        onPressed: _sttAvailable == true ? _onMicPressed : null,
        tooltip: _state.phase == VoiceLoopPhase.idle ? 'Start' : 'Stop',
        child: Icon(_state.phase == VoiceLoopPhase.idle ? Icons.mic : Icons.stop),
      ),
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.phase});

  final VoiceLoopPhase phase;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (phase) {
      VoiceLoopPhase.idle => ('idle', Colors.grey),
      VoiceLoopPhase.listening => ('listening', Colors.green),
      VoiceLoopPhase.speaking => ('speaking', Colors.blue),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
