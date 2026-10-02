import 'package:flutter/material.dart';

import '../models/doc_file.dart';

/// File-type colors shared by both themes.
abstract final class FileColors {
  static const pdf = Color(0xFFFF5A5F);
  static const word = Color(0xFF4C8DFF);
  static const excel = Color(0xFF2FD27A);
  static const powerpoint = Color(0xFFFF9A3C);
  static const other = Color(0xFFA78BFA);

  static Color of(DocKind kind) => switch (kind) {
        DocKind.pdf => pdf,
        DocKind.word => word,
        DocKind.excel => excel,
        DocKind.powerpoint => powerpoint,
        DocKind.other => other,
      };
}

/// Glass design tokens. Read with `context.palette`.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.background,
    required this.glass,
    required this.glassStrong,
    required this.glassBorder,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.accent2,
    required this.glowOpacity,
    required this.isDark,
  });

  final Color background;
  final Color glass;
  final Color glassStrong;
  final Color glassBorder;
  final Color text;
  final Color textMuted;
  final Color accent;
  final Color accent2;
  final double glowOpacity;
  final bool isDark;

  static const dark = Palette(
    background: Color(0xFF07070B),
    glass: Color(0x0FFFFFFF),
    glassStrong: Color(0x8C161620),
    glassBorder: Color(0x1FFFFFFF),
    text: Color(0xFFF4F4F8),
    textMuted: Color(0xFFB4B4C8),
    accent: Color(0xFF67E8F9),
    accent2: Color(0xFFA78BFA),
    glowOpacity: 1,
    isDark: true,
  );

  static const light = Palette(
    background: Color(0xFFF2F2F7),
    glass: Color(0xB3FFFFFF),
    glassStrong: Color(0xD9FFFFFF),
    glassBorder: Color(0x14000000),
    text: Color(0xFF101018),
    textMuted: Color(0xFF55556A),
    accent: Color(0xFF0E7490),
    accent2: Color(0xFF7C3AED),
    glowOpacity: 0.45,
    isDark: false,
  );

  @override
  Palette copyWith({Color? accent}) => Palette(
        background: background,
        glass: glass,
        glassStrong: glassStrong,
        glassBorder: glassBorder,
        text: text,
        textMuted: textMuted,
        accent: accent ?? this.accent,
        accent2: accent2,
        glowOpacity: glowOpacity,
        isDark: isDark,
      );

  @override
  Palette lerp(Palette? other, double t) {
    if (other == null) return this;
    return Palette(
      background: Color.lerp(background, other.background, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      glassStrong: Color.lerp(glassStrong, other.glassStrong, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accent2: Color.lerp(accent2, other.accent2, t)!,
      glowOpacity: glowOpacity + (other.glowOpacity - glowOpacity) * t,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

extension PaletteContext on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>() ?? Palette.dark;
}

abstract final class AppTheme {
  static const displayFont = 'Sora';
  static const bodyFont = 'Manrope';

  static ThemeData dark() => _build(Palette.dark, Brightness.dark);

  static ThemeData light() => _build(Palette.light, Brightness.light);

  static ThemeData _build(Palette p, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      surface: p.background,
      primary: p.accent,
      secondary: p.accent2,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: bodyFont,
      scaffoldBackgroundColor: p.background,
      extensions: [p],
      splashFactory: InkSparkle.splashFactory,
    );
    final text = base.textTheme.apply(bodyColor: p.text, displayColor: p.text);
    return base.copyWith(
      textTheme: text.copyWith(
        displaySmall: text.displaySmall?.copyWith(fontFamily: displayFont, fontWeight: FontWeight.w700, letterSpacing: -0.8),
        headlineMedium: text.headlineMedium?.copyWith(fontFamily: displayFont, fontWeight: FontWeight.w700, letterSpacing: -0.6),
        titleLarge: text.titleLarge?.copyWith(fontFamily: displayFont, fontWeight: FontWeight.w600),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        bodySmall: text.bodySmall?.copyWith(color: p.textMuted, fontWeight: FontWeight.w500),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.isDark ? const Color(0xFF1E1E2A) : const Color(0xFF1E1E2A),
        contentTextStyle: const TextStyle(fontFamily: bodyFont, color: Colors.white, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Colors.transparent, elevation: 0),
      iconTheme: IconThemeData(color: p.text),
    );
  }
}
