import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/doc_file.dart';
import '../theme/app_theme.dart';

/// A frosted, translucent panel: blur behind, faint fill, hairline border and
/// a soft top highlight.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.blur = 24,
    this.strong = false,
    this.glow,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Optional color that tints fill and border (used for file-type cards).
  final Color? tint;
  final double blur;

  /// Stronger, more opaque glass for floating bars and sheets.
  final bool strong;
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shape = BorderRadius.circular(radius);
    final fill = strong ? p.glassStrong : p.glass;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          if (glow != null) BoxShadow(color: glow!.withValues(alpha: 0.28 * p.glowOpacity), blurRadius: 26),
          if (strong) BoxShadow(color: Colors.black.withValues(alpha: p.isDark ? 0.45 : 0.12), blurRadius: 40, offset: const Offset(0, 16)),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: shape,
              gradient: tint == null
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [tint!.withValues(alpha: p.isDark ? 0.14 : 0.10), fill],
                    ),
              color: tint == null ? fill : null,
              border: Border.all(color: tint?.withValues(alpha: p.isDark ? 0.4 : 0.35) ?? p.glassBorder),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft neon blobs behind the glass, so the blur has something to catch.
class GlowBackground extends StatelessWidget {
  const GlowBackground({super.key, required this.child, this.colors});

  final Widget child;
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = colors ?? const [Color(0xFF7C3AED), Color(0xFF06B6D4), FileColors.pdf];
    Widget blob(Color color, double size, double opacity) => IgnorePointer(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80, tileMode: TileMode.decal),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: opacity * p.glowOpacity)),
            ),
          ),
        );
    return ColoredBox(
      color: p.background,
      child: Stack(
        children: [
          Positioned(left: -110, top: -80, child: blob(c[0], 300, 0.5)),
          Positioned(right: -90, top: 260, child: blob(c[1 % c.length], 240, 0.35)),
          Positioned(left: 20, bottom: -60, child: blob(c[2 % c.length], 240, 0.2)),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

/// Glowing glass file icon: PDF, W, X, P.
class FileTypeBadge extends StatelessWidget {
  const FileTypeBadge({super.key, required this.kind, this.size = 46});

  final DocKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = FileColors.of(kind);
    final label = switch (kind) {
      DocKind.pdf => 'PDF',
      DocKind.word => 'W',
      DocKind.excel => 'X',
      DocKind.powerpoint => 'P',
      DocKind.other => '•',
    };
    final isLetter = label.length == 1;
    return Container(
      width: size,
      height: size * 1.18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: p.isDark ? 0.45 : 0.85), color.withValues(alpha: p.isDark ? 0.08 : 0.55)],
        ),
        border: Border.all(color: Color.lerp(color, Colors.white, 0.3)!.withValues(alpha: 0.65)),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5 * p.glowOpacity), blurRadius: size * 0.5)],
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: AppTheme.displayFont,
          fontWeight: FontWeight.w700,
          fontSize: isLetter ? size * 0.48 : size * 0.22,
          letterSpacing: isLetter ? 0 : 0.6,
          color: p.isDark ? Color.lerp(color, Colors.white, 0.75) : Colors.white,
        ),
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.tooltip, this.onPressed, this.color, this.size = 44});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: size / 2,
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 20, color: color ?? context.palette.text),
        ),
      ),
    );
  }
}

class GlassChip extends StatelessWidget {
  const GlassChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? p.text : p.glass,
        shape: StadiumBorder(side: BorderSide(color: selected ? p.text : p.glassBorder)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? p.background : p.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Large glowing call-to-action button.
class NeonButton extends StatelessWidget {
  const NeonButton({super.key, required this.label, required this.onPressed, this.icon, this.colors});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null;
    final gradient = colors ?? [p.accent2, p.accent];
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(29),
          gradient: LinearGradient(colors: gradient),
          boxShadow: [BoxShadow(color: gradient.first.withValues(alpha: 0.55 * p.glowOpacity), blurRadius: 34)],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(29),
            onTap: onPressed,
            child: SizedBox(
              height: 58,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: AppTheme.displayFont,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0B0B12),
                      ),
                    ),
                  ),
                  if (icon != null) ...[
                    const SizedBox(width: 10),
                    Icon(icon, color: const Color(0xFF0B0B12), size: 20),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet shell with frosted background and grabber.
Future<T?> showGlassSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (context) => GlassPanel(
      strong: true,
      radius: 32,
      blur: 34,
      padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: context.palette.textMuted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3)),
            ),
          ),
          Builder(builder: builder),
        ],
      ),
    ),
  );
}
