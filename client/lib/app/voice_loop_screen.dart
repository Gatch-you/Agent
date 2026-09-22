import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/voice_loop_state.dart';
import '../ports/stt_port.dart';
import '../ports/tts_port.dart';
import 'theme/voice_loop_tokens.dart';
import 'widgets/ambient_glow.dart';
import 'widgets/message_bubble.dart';
import 'widgets/voice_mic_button.dart';

/// The real conversation screen (`.claude/specs/conversation-screen-visual-design.md`),
/// reproducing `design/conversation.html`. Speaks back whatever it hears (no
/// LLM yet — see `ReplyReady` in `voice_loop_state.dart`) so both the STT
/// input and the TTS output are visible: a scrolling chat history, a live
/// transcript while listening, and an animated mic button through
/// idle/listening/thinking/speaking.
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
  int? _playingMessageIndex;

  final _scrollController = ScrollController();
  final _sessionStart = DateTime.now();
  late final Timer _sessionTimer;
  Duration _sessionElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    widget.stt.initialize().then((available) {
      if (!mounted) return;
      setState(() => _sttAvailable = available);
    });
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _sessionElapsed = DateTime.now().difference(_sessionStart));
    });
  }

  @override
  void dispose() {
    _sessionTimer.cancel();
    _scrollController.dispose();
    widget.stt.dispose();
    widget.tts.dispose();
    super.dispose();
  }

  void _onMicPressed() {
    switch (_state.phase) {
      case VoiceLoopPhase.idle:
        _start();
      case VoiceLoopPhase.listening:
      case VoiceLoopPhase.speaking:
        _stop();
      case VoiceLoopPhase.thinking:
        break; // no-op: mic is disabled while thinking, mirroring the mockup.
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
        _scrollToBottom();
      },
      onFinalResult: (text) async {
        if (!mounted) return;
        // Guard against acting twice on the same utterance: some STT
        // adapters can emit more than one final result in quick succession
        // (e.g. DictationTranscriberStt's silence-timeout synthetic final,
        // followed by the real one once finalizeAndFinishThroughEndOfInput()
        // actually completes). Checking only the resulting phase isn't
        // enough — once already past `listening`, a second final would still
        // see a non-`listening` phase and re-trigger this whole turn (this
        // exact double-trigger crashed the native Speech framework once by
        // tearing its session down twice — see DictationTranscriberBridge.swift).
        final wasListening = _state.phase == VoiceLoopPhase.listening;
        setState(() => _state = _state.reduce(FinalResult(text)));
        if (!wasListening || _state.phase != VoiceLoopPhase.thinking) return;
        _scrollToBottom();

        final userText = _state.messages.last.text;
        await widget.stt.stopListening();

        // Stand-in for real LLM latency — there's no CascadeSession/LlmPort
        // yet (see .claude/specs/conversation-screen-visual-design.md), so
        // this is just a short fixed beat before echoing the reply back.
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        setState(() => _state = _state.reduce(ReplyReady(userText)));
        if (_state.phase != VoiceLoopPhase.speaking) return;
        _scrollToBottom();

        final reply = _state.messages.last.text;
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: voiceLoopEaseStandard,
      );
    });
  }

  /// Replays TTS for one assistant message. Only one plays at a time.
  /// [TtsPort] has no `stop()` (out of scope to add here — see the spec), so
  /// tapping a different bubble while one is already playing is ignored
  /// rather than risking two overlapping/queued utterances; tapping the
  /// currently-playing bubble again just clears the visual indicator.
  void _toggleMessagePlayback(int index, String text) {
    if (_playingMessageIndex == index) {
      setState(() => _playingMessageIndex = null);
      return;
    }
    if (_playingMessageIndex != null) return;

    setState(() => _playingMessageIndex = index);
    widget.tts.speak(
      text,
      onComplete: () {
        if (!mounted || _playingMessageIndex != index) return;
        setState(() => _playingMessageIndex = null);
      },
    );
  }

  String get _stateLabel => switch (_state.phase) {
    VoiceLoopPhase.idle => 'Tap to start',
    VoiceLoopPhase.listening => 'Listening…',
    VoiceLoopPhase.thinking => 'Thinking…',
    VoiceLoopPhase.speaking => 'Speaking…',
  };

  Color get _stateDotColor => switch (_state.phase) {
    VoiceLoopPhase.idle => VoiceLoopColors.labelTertiary,
    VoiceLoopPhase.listening => VoiceLoopColors.accent,
    VoiceLoopPhase.thinking => VoiceLoopColors.labelTertiary,
    VoiceLoopPhase.speaking => VoiceLoopColors.danger,
  };

  String get _sessionLabel {
    final m = _sessionElapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_sessionElapsed.inSeconds % 60).toString().padLeft(2, '0');
    return 'Session · $m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VoiceLoopColors.bgGrouped,
      body: Stack(
        children: [
          Positioned.fill(
            child: AmbientGlow(
              intensified:
                  _state.phase == VoiceLoopPhase.listening ||
                  _state.phase == VoiceLoopPhase.speaking,
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _NavBar(subtitle: _sessionLabel),
                Expanded(child: _buildMessageList()),
                _buildLiveTranscript(),
                _buildControlArea(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    final showThinking = _state.phase == VoiceLoopPhase.thinking;
    final itemCount = _state.messages.length + (showThinking ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: VoiceLoopSpacing.lg,
        vertical: VoiceLoopSpacing.sm,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (showThinking && index == _state.messages.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: VoiceLoopSpacing.xs / 2),
            child: ThinkingBubble(),
          );
        }
        final message = _state.messages[index];
        return MessageBubble(
          key: ValueKey('message-$index'),
          message: message,
          isPlaying: _playingMessageIndex == index,
          onTogglePlay: message.role == MessageRole.assistant
              ? () => _toggleMessagePlayback(index, message.text)
              : null,
        );
      },
    );
  }

  Widget _buildLiveTranscript() {
    final hasText = _state.liveTranscript.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VoiceLoopSpacing.xl,
        0,
        VoiceLoopSpacing.xl,
        VoiceLoopSpacing.xs,
      ),
      child: SizedBox(
        height: 22,
        child: hasText
            ? Align(
                alignment: Alignment.centerRight,
                child: _BlinkingCaretText(text: _state.liveTranscript),
              )
            : null,
      ),
    );
  }

  Widget _buildControlArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(0, VoiceLoopSpacing.sm, 0, VoiceLoopSpacing.lg),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0x8C000000), Color(0x00000000)],
          stops: [0, 0.55],
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(shape: BoxShape.circle, color: _stateDotColor),
              ),
              Text(_stateLabel, style: VoiceLoopTextStyles.footnote),
            ],
          ),
          const SizedBox(height: VoiceLoopSpacing.sm),
          VoiceMicButton(
            phase: _state.phase,
            onPressed: (_sttAvailable == true && _state.phase != VoiceLoopPhase.thinking)
                ? _onMicPressed
                : null,
          ),
          const SizedBox(height: VoiceLoopSpacing.sm),
          Text(
            _sttAvailable == false
                ? 'Speech recognition is not available on this device.'
                : 'Tap the mic and start speaking',
            style: VoiceLoopTextStyles.caption,
          ),
        ],
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VoiceLoopSpacing.lg,
        VoiceLoopSpacing.xs,
        VoiceLoopSpacing.lg,
        VoiceLoopSpacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('English Practice', style: VoiceLoopTextStyles.headline),
              Text(subtitle, style: VoiceLoopTextStyles.caption),
            ],
          ),
          // History screen isn't built yet (see the spec's Out of scope) —
          // this stays a plain, always-enabled-looking icon with no handler,
          // matching the mockup's own inert button.
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(color: Color(0x1F787880), shape: BoxShape.circle),
            child: const Icon(Icons.history_rounded, size: 16, color: VoiceLoopColors.accent),
          ),
        ],
      ),
    );
  }
}

class _BlinkingCaretText extends StatefulWidget {
  const _BlinkingCaretText({required this.text});

  final String text;

  @override
  State<_BlinkingCaretText> createState() => _BlinkingCaretTextState();
}

class _BlinkingCaretTextState extends State<_BlinkingCaretText> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            widget.text,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: VoiceLoopTextStyles.subhead.copyWith(fontStyle: FontStyle.italic),
          ),
        ),
        const SizedBox(width: 2),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Opacity(
              opacity: _controller.value < 0.5 ? 1 : 0,
              child: Container(width: 2, height: 15, color: VoiceLoopColors.labelSecondary),
            );
          },
        ),
      ],
    );
  }
}
