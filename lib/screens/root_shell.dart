import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../services/incoming_files.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'convert_screen.dart';
import 'create_sheet.dart';
import 'files_screen.dart';
import 'home_screen.dart';
import 'images_to_pdf_screen.dart';
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
  late final _incoming = IncomingFiles(_receive)..start();

  @override
  void initState() {
    super.initState();
    _incoming;
  }

  @override
  void dispose() {
    _incoming.stop();
    super.dispose();
  }

  /// Opens files from other apps: documents go into the library and the
  /// first one opens; pictures go to "Pictures to PDF".
  Future<void> _receive(List<IncomingFile> files) async {
    final library = AppScope.of(context).library;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final documents = <DocFile>[];
    final pictures = <Uint8List>[];
    var skipped = 0;
    for (final f in files) {
      try {
        final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
        if (f.path.isEmpty) {
          // The phone could not copy it.
          skipped++;
        } else if (f.isImage) {
          pictures.add(await File(f.path).readAsBytes());
        } else if (supportedExtensions.contains(ext)) {
          documents.add(await library.importBytes(f.name, await File(f.path).readAsBytes()));
        } else {
          skipped++;
        }
      } catch (_) {
        skipped++;
      } finally {
        await f.discard();
      }
    }
    if (!mounted) return;
    if (skipped > 0) {
      messenger.showSnackBar(SnackBar(content: Text(skipped == 1 ? 'One file could not be opened.' : '$skipped files could not be opened.')));
    }
    if (pictures.isNotEmpty) {
      if (documents.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text('Added ${documents.length} ${documents.length == 1 ? 'file' : 'files'} to your library.')));
      // Pictures shared while "Pictures to PDF" is showing join those pages.
      if (ImagesToPdfScreen.addToOpen(pictures)) {
        messenger.showSnackBar(SnackBar(content: Text('Added ${pictures.length} ${pictures.length == 1 ? 'picture' : 'pictures'} to the PDF.')));
      } else {
        // Not awaited: more files may arrive while this screen is open.
        unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => ImagesToPdfScreen(initial: pictures))));
      }
    } else if (documents.isNotEmpty) {
      if (documents.length > 1) messenger.showSnackBar(SnackBar(content: Text('Added ${documents.length} files. Opening the first.')));
      unawaited(openDocument(context, documents.first));
    }
  }

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
      bottomNavigationBar: GlassTabBar(current: _tab, onSelect: _select, onAdd: () => showCreateSheet(context)),
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
