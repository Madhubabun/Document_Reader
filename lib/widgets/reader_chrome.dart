import 'package:flutter/material.dart';

import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import 'glass.dart';

/// Color matrices used to tint document pages for comfortable reading.
ColorFilter? pageToneFilter(PageTone tone) => switch (tone) {
      PageTone.light => null,
      PageTone.sepia => const ColorFilter.matrix([
          0.94, 0.06, 0.0, 0, 0, //
          0.04, 0.86, 0.04, 0, 0,
          0.02, 0.06, 0.66, 0, 0,
          0, 0, 0, 1, 0,
        ]),
      // Inverts luminance so white pages become charcoal and text turns light.
      PageTone.night => const ColorFilter.matrix([
          -0.86, 0, 0, 0, 236, //
          0, -0.86, 0, 0, 236,
          0, 0, -0.86, 0, 242,
          0, 0, 0, 1, 0,
        ]),
    };

/// Floating glass top bar used by every reader.
class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({super.key, required this.title, required this.subtitle, this.actions = const []});

  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      bottom: false,
      minimum: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: GlassPanel(
        strong: true,
        radius: 24,
        blur: 30,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(tooltip: 'Back', onPressed: () => Navigator.maybePop(context), icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20)),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 1),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.textMuted)),
                  ],
                ),
              ),
              ...actions,
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class DockAction {
  const DockAction(this.icon, this.label, this.onTap, {this.active = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
}

/// Floating glowing tool dock at the bottom of a reader.
class ReaderDock extends StatelessWidget {
  const ReaderDock({super.key, required this.actions});

  final List<DockAction> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final neon = p.isDark ? const Color(0xFFA5F3FC) : p.accent;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: [BoxShadow(color: const Color(0xFF22D3EE).withValues(alpha: 0.22 * p.glowOpacity), blurRadius: 30)],
        ),
        child: GlassPanel(
          strong: true,
          radius: 28,
          blur: 30,
          child: SizedBox(
            height: 72,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final a in actions)
                  Semantics(
                    button: true,
                    selected: a.active,
                    label: a.label,
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: a.onTap,
                      child: Container(
                        width: 62,
                        height: 58,
                        decoration: a.active
                            ? BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                color: neon.withValues(alpha: 0.14),
                                border: Border.all(color: neon.withValues(alpha: 0.45)),
                              )
                            : null,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(a.icon, size: 21, color: neon, shadows: p.isDark ? [Shadow(color: neon.withValues(alpha: 0.8), blurRadius: 8)] : null),
                            const SizedBox(height: 4),
                            Text(a.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.text)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lets the user pick a page tone from a reader.
Future<void> showPageToneSheet(BuildContext context, SettingsStore settings) {
  return showGlassSheet<void>(
    context,
    (sheet) => ListenableBuilder(
      listenable: settings,
      builder: (sheet, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Page color', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 14),
          SegmentedButton<PageTone>(
            segments: const [
              ButtonSegment(value: PageTone.light, label: Text('Paper'), icon: Icon(Icons.wb_sunny_outlined)),
              ButtonSegment(value: PageTone.sepia, label: Text('Sepia'), icon: Icon(Icons.coffee_outlined)),
              ButtonSegment(value: PageTone.night, label: Text('Night'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {settings.pageTone},
            onSelectionChanged: (s) => settings.setPageTone(s.first),
          ),
        ],
      ),
    ),
  );
}
