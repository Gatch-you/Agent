import 'package:flutter/material.dart';

/// Design tokens ported 1:1 from `design/tokens.css` — keep the names and
/// values in sync with that file rather than re-guessing colors/spacing here.
/// See `design/conversation.html` for the mockup these back.
abstract final class VoiceLoopColors {
  static const accent = Color(0xFF0A84FF);
  static const accentPressed = Color(0xFF409CFF);
  static const danger = Color(0xFFFF453A);
  static const success = Color(0xFF32D74B);

  static const bgGrouped = Color(0xFF000000);
  static const bgSurface = Color(0x1FFFFFFF); // rgba(255,255,255,0.12)
  static const bgBubbleAssistant = Color(0xFF2C2C2E);

  static const labelPrimary = Color(0xF2FFFFFF); // rgba(255,255,255,0.95)
  static const labelSecondary = Color(0x99EBEBF5); // rgba(235,235,245,0.6)
  static const labelTertiary = Color(0x4DEBEBF5); // rgba(235,235,245,0.3)
  static const labelOnAccent = Color(0xFFFFFFFF);

  static const separator = Color(0x99545458); // rgba(84,84,88,0.6)

  static const glow1 = accent;
  static const glow2 = Color(0xFFBF5AF2);
  static const glow3 = Color(0xFFFF375F);
}

abstract final class VoiceLoopSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class VoiceLoopRadius {
  static const bubble = 18.0;
  static const card = 14.0;
  static const pill = 999.0;
}

abstract final class VoiceLoopTextStyles {
  static const largeTitle = TextStyle(
    fontWeight: FontWeight.w700,
    fontSize: 34,
    height: 41 / 34,
    color: VoiceLoopColors.labelPrimary,
  );
  static const headline = TextStyle(
    fontWeight: FontWeight.w600,
    fontSize: 17,
    height: 22 / 17,
    color: VoiceLoopColors.labelPrimary,
  );
  static const body = TextStyle(
    fontWeight: FontWeight.w400,
    fontSize: 17,
    height: 22 / 17,
    color: VoiceLoopColors.labelPrimary,
  );
  static const subhead = TextStyle(
    fontWeight: FontWeight.w400,
    fontSize: 15,
    height: 20 / 15,
    color: VoiceLoopColors.labelSecondary,
  );
  static const footnote = TextStyle(
    fontWeight: FontWeight.w400,
    fontSize: 13,
    height: 18 / 13,
    color: VoiceLoopColors.labelSecondary,
  );
  static const caption = TextStyle(
    fontWeight: FontWeight.w500,
    fontSize: 12,
    height: 16 / 12,
    color: VoiceLoopColors.labelSecondary,
  );
}

/// `--ease-standard` from tokens.css.
const voiceLoopEaseStandard = Cubic(0.25, 0.1, 0.25, 1);
