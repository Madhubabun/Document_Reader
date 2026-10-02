import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final p = context.palette;
    Widget section(String title, List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(title.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: p.textMuted)),
            ),
            GlassPanel(radius: 20, padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: children)),
            const SizedBox(height: 22),
          ],
        );

    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 130),
          children: [
            Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 18),
            section('Appearance', [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                    ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (s) => settings.setThemeMode(s.first),
                ),
              ),
            ]),
            section('Reading', [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SegmentedButton<PageTone>(
                  segments: const [
                    ButtonSegment(value: PageTone.light, label: Text('Paper')),
                    ButtonSegment(value: PageTone.sepia, label: Text('Sepia')),
                    ButtonSegment(value: PageTone.night, label: Text('Night')),
                  ],
                  selected: {settings.pageTone},
                  onSelectionChanged: (s) => settings.setPageTone(s.first),
                ),
              ),
            ]),
            section('Office compatibility', [
              ListTile(
                leading: const Icon(Icons.verified_outlined, color: FileColors.excel),
                title: const Text('Files open in Microsoft 365', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                  'Documents are read and saved as standard .docx, .xlsx and .pptx (Office Open XML), with Calibri and Arial as default fonts. '
                  'Macros, embedded objects, heavy SmartArt and precisely placed floating shapes may look slightly different, which is normal for any mobile editor.',
                  style: TextStyle(color: p.textMuted, height: 1.4),
                ),
              ),
            ]),
            section('About', [
              ListTile(
                title: const Text('Doc Reader', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('Free-first, offline, no account needed.', style: TextStyle(color: p.textMuted)),
              ),
              ListTile(
                title: const Text('Open-source licenses', style: TextStyle(fontWeight: FontWeight.w600)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showLicensePage(context: context, applicationName: 'Doc Reader'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
