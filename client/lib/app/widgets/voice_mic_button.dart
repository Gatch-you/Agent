import 'package:flutter/material.dart';

import '../../domain/voice_loop_state.dart';
import '../theme/voice_loop_tokens.dart';

/// The circular mic/stop button with a pulsing expanding-ring animation,
/// porting `.mic-wrap`/`.mic-ring`/`.mic-button` and the per-phase styling
/// from `design/conversation.html`.
class VoiceMicButton extends StatefulWidget {
  const VoiceMicButton({super.key, required this.phase, required this.onPressed});

  final VoiceLoopPhase phase;

  /// Null disables the button (thinking phase, or STT not ready yet).
  final VoidCallback? onPressed;

  @override
  State<VoiceMicButton> createState() => _VoiceMicButtonState();
}

class _VoiceMicButtonState extends State<VoiceMicButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ringController;

  bool get _ringActive =>
      widget.phase == VoiceLoopPhase.listening || widget.phase == VoiceLoopPhase.speaking;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(vsync: this, duration: _ringDuration);
    if (_ringActive) _ringController.repeat();
  }

  Duration get _ringDuration =>
      widget.phase == VoiceLoopPhase.speaking
          ? const Duration(milliseconds: 1400)
          : const Duration(milliseconds: 1800);

  @override
  void didUpdateWidget(covariant VoiceMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) {
      _ringController.duration = _ringDuration;
      if (_ringActive) {
        _ringController.repeat();
      } else {
        _ringController.stop();
      }
    }
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  (Color background, Color foreground) get _buttonColors => switch (widget.phase) {
    VoiceLoopPhase.idle => (VoiceLoopColors.bgSurface, VoiceLoopColors.accent),
    VoiceLoopPhase.listening => (VoiceLoopColors.accent, VoiceLoopColors.labelOnAccent),
    VoiceLoopPhase.thinking => (const Color(0x2E787880), VoiceLoopColors.labelTertiary),
    VoiceLoopPhase.speaking => (VoiceLoopColors.danger, VoiceLoopColors.labelOnAccent),
  };

  Color get _ringColor =>
      widget.phase == VoiceLoopPhase.speaking ? VoiceLoopColors.danger : VoiceLoopColors.accent;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = _buttonColors;

    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_ringActive)
            AnimatedBuilder(
              animation: _ringController,
              builder: (context, _) {
                final t = _ringController.value;
                return Opacity(
                  opacity: (0.55 * (1 - t)).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 1 + 0.55 * t,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: _ringColor, width: 2),
                      ),
                    ),
                  ),
                );
              },
            ),
          GestureDetector(
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: background,
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 20, offset: Offset(0, 4))],
              ),
              child: Icon(
                widget.phase == VoiceLoopPhase.speaking ? Icons.stop_rounded : Icons.mic_rounded,
                size: 28,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
