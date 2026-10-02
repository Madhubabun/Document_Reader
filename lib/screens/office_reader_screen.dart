import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../services/ooxml/docx_reader.dart';
import '../services/ooxml/pptx_reader.dart';
import '../services/ooxml/xlsx_reader.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/reader_chrome.dart';
import 'office/slides_view.dart';
import 'office/spreadsheet_view.dart';
import 'office/word_view.dart';

/// Parses an OOXML file off the UI thread.
Future<Object> parseOfficeFile(String path) async {
  final bytes = await File(path).readAsBytes();
  return compute(_parse, (DocKind.fromPath(path), bytes));
}

Object _parse((DocKind, Uint8List) input) => switch (input.$1) {
      DocKind.word => DocxReader.read(input.$2),
      DocKind.excel => XlsxReader.read(input.$2),
      DocKind.powerpoint => PptxReader.read(input.$2),
      _ => throw UnsupportedError('Not an Office file'),
    };

/// Reader for Word, Excel and PowerPoint files.
class OfficeReaderScreen extends StatefulWidget {
  const OfficeReaderScreen({super.key, required this.file});

  final DocFile file;

  @override
  State<OfficeReaderScreen> createState() => _OfficeReaderScreenState();
}

class _OfficeReaderScreenState extends State<OfficeReaderScreen> {
  late final Future<Object> _parsed = parseOfficeFile(widget.file.path);
  final _outlineRequests = ValueNotifier<int>(0);
  String _subtitle = 'Opening…';

  @override
  void dispose() {
    _outlineRequests.dispose();
    super.dispose();
  }

  void _setSubtitle(String value) {
    if (value == _subtitle) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _subtitle = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final p = context.palette;
    final kind = widget.file.kind;
    return Scaffold(
      backgroundColor: p.background,
      body: GlowBackground(
        colors: [FileColors.of(kind), const Color(0xFF7C3AED), const Color(0xFF06B6D4)],
        child: Stack(
          children: [
            Positioned.fill(
              child: FutureBuilder<Object>(
                future: _parsed,
                builder: (context, snap) {
                  if (snap.hasError) {
                    _setSubtitle('Could not open');
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                          'This file could not be opened. It may be damaged or password protected.\n\n${snap.error}',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.textMuted, height: 1.4),
                        ),
                      ),
                    );
                  }
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  return ListenableBuilder(
                    listenable: settings,
                    builder: (context, _) => switch (snap.data!) {
                      DocxDocument d => WordView(document: d, tone: settings.pageTone, outlineRequests: _outlineRequests, onStatus: _setSubtitle),
                      XlsxWorkbook w => SpreadsheetView(workbook: w, onStatus: _setSubtitle),
                      PptxPresentation s => SlidesView(presentation: s, outlineRequests: _outlineRequests, onStatus: _setSubtitle),
                      _ => const SizedBox.shrink(),
                    },
                  );
                },
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: ReaderTopBar(
                title: widget.file.name,
                subtitle: _subtitle,
                actions: [IconButton(tooltip: 'Share', onPressed: () => shareDocument(widget.file), icon: const Icon(Icons.ios_share_rounded, size: 21))],
              ),
            ),
            if (kind != DocKind.excel)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ReaderDock(actions: [
                  DockAction(
                    kind == DocKind.powerpoint ? Icons.view_carousel_outlined : Icons.format_list_bulleted_rounded,
                    kind == DocKind.powerpoint ? 'Slides' : 'Outline',
                    () => _outlineRequests.value++,
                  ),
                  DockAction(Icons.edit_outlined, 'Edit', () {
                    showComingSoon(
                      context,
                      'Editing ${kind.label}',
                      'Editing text, formatting, images and tables is being built next, saved as standard ${widget.file.extension} that opens in Microsoft 365.',
                    );
                  }),
                  if (kind == DocKind.word) DockAction(Icons.contrast_rounded, 'Page', () => showPageToneSheet(context, settings)),
                  DockAction(Icons.ios_share_rounded, 'Share', () => shareDocument(widget.file)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
