import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../services/library_store.dart';
import '../services/new_documents.dart';
import '../services/scanner.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/text_dialog.dart';
import 'images_to_pdf_screen.dart';
import 'office_reader_screen.dart';
import 'pdf_reader_screen.dart';
import 'pdf_tools_screen.dart';

DocKind _docKind(NewKind kind) => switch (kind) {
      NewKind.word => DocKind.word,
      NewKind.excel => DocKind.excel,
      NewKind.powerpoint => DocKind.powerpoint,
      NewKind.pdf => DocKind.pdf,
    };

/// Everything the + button can make: scans, PDFs from photos, new Office
/// files, PDF tools and imports.
Future<void> showCreateSheet(BuildContext context) async {
  final picked = await showGlassSheet<VoidCallback>(context, (sheet) {
    Widget row(String label, String detail, Widget leading, Key key, void Function(BuildContext) action) => ListTile(
          key: key,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: leading,
          title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(detail, style: TextStyle(fontSize: 12, color: sheet.palette.textMuted)),
          onTap: () => Navigator.pop(sheet, () => action(context)),
        );
    Widget icon(IconData icon, Color color) => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Icon(icon, color: color, size: 21),
        );
    return Flexible(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Create', style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 6),
            row('Scan a document', 'Use the camera; pages are found and straightened', icon(Icons.document_scanner_outlined, const Color(0xFF67E8F9)),
                const Key('create-scan'), startScan),
            row('Photos to PDF', 'Pick pictures from your gallery', icon(Icons.photo_library_outlined, FileColors.pdf), const Key('create-photos'),
                (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const ImagesToPdfScreen()))),
            for (final kind in [NewKind.word, NewKind.excel, NewKind.powerpoint])
              row('New ${kind.label}', 'Blank or from a template, ready for Microsoft 365', FileTypeBadge(kind: _docKind(kind), size: 40),
                  Key('create-${kind.name}'), (c) => showTemplateSheet(c, kind)),
            row('PDF tools', 'Merge, split, compress, lock and more', icon(Icons.handyman_outlined, const Color(0xFFA78BFA)), const Key('create-tools'),
                (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const PdfToolsScreen()))),
            row('Import a file', 'PDF, Word, Excel or PowerPoint', icon(Icons.file_download_outlined, const Color(0xFF7AA2FF)), const Key('create-import'),
                (c) => importDocuments(c)),
          ],
        ),
      ),
    );
  });
  if (picked != null && context.mounted) picked();
}

/// Scans pages with the camera and opens them ready to become a PDF.
Future<void> startScan(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  try {
    final pages = await scanPages();
    if (pages == null || pages.isEmpty) return;
    await navigator.push(MaterialPageRoute<void>(builder: (_) => ImagesToPdfScreen(initial: pages, scanned: true)));
  } on ScanUnavailable catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('The scan did not work: $e')));
  }
}

/// Lists the templates for [kind]; picking one creates the file.
Future<void> showTemplateSheet(BuildContext context, NewKind kind) async {
  final templates = newTemplates.where((t) => t.kind == kind).toList();
  final picked = await showGlassSheet<NewTemplate>(
    context,
    (sheet) => Flexible(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New ${kind.label}', style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              kind == NewKind.pdf
                  ? 'Standard PDF that opens anywhere.'
                  : 'Saved as .${kind.extension} with Calibri text, so it opens in Microsoft 365 on Windows, Mac and the web.',
              style: TextStyle(fontSize: 12, color: sheet.palette.textMuted),
            ),
            const SizedBox(height: 8),
            for (final t in templates)
              ListTile(
                key: Key('template-${t.name}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: FileTypeBadge(kind: _docKind(kind), size: 40),
                title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(t.description, style: TextStyle(fontSize: 12, color: sheet.palette.textMuted)),
                onTap: () => Navigator.pop(sheet, t),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked != null && context.mounted) await createFromTemplate(context, picked);
}

/// Asks for a name, makes the file from [template], adds it to the library
/// and opens it (Word and PowerPoint straight into editing).
Future<DocFile?> createFromTemplate(BuildContext context, NewTemplate template) async {
  final library = AppScope.of(context).library;
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final fallback = template.name == 'Blank' || template.name == 'Blank page'
      ? switch (template.kind) {
          NewKind.word => 'Document',
          NewKind.excel => 'Workbook',
          NewKind.powerpoint => 'Presentation',
          NewKind.pdf => 'Blank',
        }
      : template.name;
  final typed = await showTextDialog(context, title: 'Name your ${template.kind.label.toLowerCase()}', initial: fallback, fieldKey: const Key('new-name'));
  if (typed == null) return null;
  final name = safeBaseName(typed, fallback: fallback, extension: template.kind.extension);
  try {
    final bytes = await template.build(name);
    final file = await library.importBytes('$name.${template.kind.extension}', bytes);
    await library.markOpened(file);
    if (!navigator.mounted) return file;
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => template.kind == NewKind.pdf
          ? PdfReaderScreen(file: file)
          : OfficeReaderScreen(file: file, startEditing: template.kind != NewKind.excel),
    ));
    return file;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not create the file: $e')));
    return null;
  }
}
