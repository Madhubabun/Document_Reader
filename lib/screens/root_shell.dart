import 'package:flutter/material.dart';

import '../services/document_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'convert_screen.dart';
import 'files_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

enum AppTab { home, files, convert, settings }

/// Hosts the four main tabs under a floating glass tab bar.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  AppTab _tab = AppTab.home;

  void _select(AppTab tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: GlowBackground(
        child: IndexedStack(
          index: _tab.index,
          children: [
            HomeScreen(onOpenTab: _select),
            const FilesScreen(),
            const ConvertScreen(),
            const SettingsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: GlassTabBar(current: _tab, onSelect: _select, onAdd: () => importDocuments(context)),
    );
  }
}

class GlassTabBar extends StatelessWidget {
  const GlassTabBar({super.key, required this.current, required this.onSelect, required this.onAdd});

  final AppTab current;
  final ValueChanged<AppTab> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget item(AppTab tab, IconData icon, IconData activeIcon, String label) {
      final selected = tab == current;
      return Semantics(
        selected: selected,
        child: IconButton(
          tooltip: label,
          onPressed: () => onSelect(tab),
          icon: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? activeIcon : icon, color: selected ? p.accent : p.textMuted, size: 24),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: selected ? 5 : 0,
                height: 5,
                decoration: BoxDecoration(
                  color: p.accent,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.8 * p.glowOpacity), blurRadius: 8)],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(18, 0, 18, 16),
      child: GlassPanel(
        strong: true,
        radius: 35,
        blur: 30,
        child: SizedBox(
          height: 70,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              item(AppTab.home, Icons.home_outlined, Icons.home_rounded, 'Home'),
              item(AppTab.files, Icons.folder_outlined, Icons.folder_rounded, 'Files'),
              Tooltip(
                message: 'Import a document',
                child: GestureDetector(
                  onTap: onAdd,
                  child: Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [p.accent, p.accent2]),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
                      boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.55 * p.glowOpacity), blurRadius: 28)],
                    ),
                    child: const Icon(Icons.add_rounded, color: Color(0xFF0B0B12), size: 28),
                  ),
                ),
              ),
              item(AppTab.convert, Icons.swap_horiz_rounded, Icons.swap_horiz_rounded, 'Convert'),
              item(AppTab.settings, Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
            ],
          ),
        ),
      ),
    );
  }
}
