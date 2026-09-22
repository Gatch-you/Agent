import 'package:flutter/material.dart';

import '../../domain/voice_loop_state.dart';
import '../theme/voice_loop_tokens.dart';

/// One chat bubble, porting `.bubble`/`.bubble-row`/`.play-button` from
/// `design/conversation.html`: assistant bubbles left/grey with a play
/// button that replays TTS, user bubbles right/accent, and a fade+slide-in
/// entrance the first time a bubble appears (`@keyframes bubble-in`).
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.isPlaying = false,
    this.onTogglePlay,
  });

  final VoiceLoopMessage message;

  /// Only meaningful for assistant messages.
  final bool isPlaying;
  final VoidCallback? onTogglePlay;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();
  late final _fade = CurvedAnimation(parent: _controller, curve: voiceLoopEaseStandard);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.role == MessageRole.user;

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(_fade),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: VoiceLoopSpacing.xs / 2),
          child: Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser) ...[
                _PlayButton(isPlaying: widget.isPlaying, onPressed: widget.onTogglePlay),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                  padding: const EdgeInsets.symmetric(
                    horizontal: VoiceLoopSpacing.md,
                    vertical: VoiceLoopSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: isUser ? VoiceLoopColors.accent : VoiceLoopColors.bgBubbleAssistant,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(VoiceLoopRadius.bubble),
                      topRight: const Radius.circular(VoiceLoopRadius.bubble),
                      bottomLeft: Radius.circular(isUser ? VoiceLoopRadius.bubble : 4),
                      bottomRight: Radius.circular(isUser ? 4 : VoiceLoopRadius.bubble),
                    ),
                  ),
                  child: Text(
                    widget.message.text,
                    style: VoiceLoopTextStyles.body.copyWith(
                      color: isUser ? VoiceLoopColors.labelOnAccent : VoiceLoopColors.labelPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The three-dot "thinking" bubble (`.bubble--thinking`), shown in place of
/// an assistant message while a reply is being prepared.
class ThinkingBubble extends StatefulWidget {
  const ThinkingBubble({super.key});

  @override
  State<ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<ThinkingBubble> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: VoiceLoopSpacing.md, vertical: 14),
        decoration: BoxDecoration(
          color: VoiceLoopColors.bgBubbleAssistant,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(VoiceLoopRadius.bubble),
            topRight: Radius.circular(VoiceLoopRadius.bubble),
            bottomRight: Radius.circular(VoiceLoopRadius.bubble),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = (_controller.value - i * 0.15) % 1.0;
                  // Mirrors @keyframes dot-bounce: up then down, over 60% of the cycle.
                  final bounce = t < 0.3
                      ? t / 0.3
                      : t < 0.6
                          ? 1 - (t - 0.3) / 0.3
                          : 0.0;
                  return Transform.translate(
                    offset: Offset(0, -4 * bounce),
                    child: Opacity(
                      opacity: 0.5 + 0.5 * bounce,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: VoiceLoopColors.labelTertiary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.isPlaying, required this.onPressed});

  final bool isPlaying;
  final VoidCallback? onPressed;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: voiceLoopEaseStandard,
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.isPlaying ? VoiceLoopColors.accent : VoiceLoopColors.bgSurface,
          border: widget.isPlaying
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Center(
          child: widget.isPlaying
              ? _Equalizer(controller: _controller)
              : Icon(Icons.play_arrow_rounded, size: 15, color: VoiceLoopColors.accent),
        ),
      ),
    );
  }
}

class _Equalizer extends StatelessWidget {
  const _Equalizer({required this.controller});

  final Animation<double> controller;

  @override
  Widget build(BuildContext context) {
    const heights = [5.0, 11.0, 7.0];
    const delays = [0.0, 0.15, 0.3];
    return SizedBox(
      width: 12,
      height: 11,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(3, (i) {
          return Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final t = (controller.value + delays[i]) % 1.0;
                // Mirrors @keyframes eq-bounce: scaleY 0.35 -> 1 -> 0.35.
                final phase = (t < 0.5 ? t / 0.5 : 1 - (t - 0.5) / 0.5);
                final scaleY = 0.35 + 0.65 * phase;
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: Transform.scale(
                    scaleY: scaleY,
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: 2.5,
                      height: heights[i],
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }
}
