import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/voice_loop_tokens.dart';

/// The "Siri effect" — a few soft, blurred, slowly-drifting color blobs
/// behind everything else. Ports `.ambient-glow`/`.glow-blob` from
/// `design/conversation.html`: low-opacity and slow on purpose (ambient
/// light, not a shape you consciously notice), intensifying slightly while
/// listening/speaking.
///
/// On a near-black background, CSS `mix-blend-mode: screen` over black is
/// visually equivalent to plain alpha compositing (screen(0, c) == c), so
/// this uses ordinary translucent circles rather than reproducing a true
/// blend mode.
class AmbientGlow extends StatefulWidget {
  const AmbientGlow({super.key, this.intensified = false});

  final bool intensified;

  @override
  State<AmbientGlow> createState() => _AmbientGlowState();
}

class _AmbientGlowState extends State<AmbientGlow> with TickerProviderStateMixin {
  late final _controllers = [
    AnimationController(vsync: this, duration: const Duration(seconds: 16))..repeat(reverse: true),
    AnimationController(vsync: this, duration: const Duration(seconds: 19))..repeat(reverse: true),
    AnimationController(vsync: this, duration: const Duration(seconds: 13))..repeat(reverse: true),
  ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.intensified ? 0.85 : 0.55,
        duration: const Duration(milliseconds: 600),
        curve: voiceLoopEaseStandard,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _GlowBlob(
              controller: _controllers[0],
              size: 260,
              color: VoiceLoopColors.glow1,
              left: -70,
              bottom: -60,
              driftOffset: const Offset(30, -25),
              endScale: 1.15,
            ),
            _GlowBlob(
              controller: _controllers[1],
              size: 230,
              color: VoiceLoopColors.glow2,
              right: -60,
              bottom: 10,
              driftOffset: const Offset(-25, -15),
              endScale: 1.1,
            ),
            _GlowBlob(
              controller: _controllers[2],
              size: 200,
              color: VoiceLoopColors.glow3,
              left: 110,
              bottom: -100,
              driftOffset: const Offset(15, 20),
              endScale: 1.2,
            ),
          ],
        ),
      ),
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({
    required this.controller,
    required this.size,
    required this.color,
    required this.bottom,
    required this.driftOffset,
    required this.endScale,
    this.left,
    this.right,
  });

  final AnimationController controller;
  final double size;
  final Color color;
  final double bottom;
  final double? left;
  final double? right;
  final Offset driftOffset;
  final double endScale;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      right: right,
      bottom: bottom,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final t = controller.value;
          return Transform.translate(
            offset: Offset(driftOffset.dx * t, driftOffset.dy * t),
            child: Transform.scale(
              scale: 1 + (endScale - 1) * t,
              child: child,
            ),
          );
        },
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }
}
