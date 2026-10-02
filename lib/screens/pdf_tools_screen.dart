import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/new_documents.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'create_sheet.dart';
import 'pdf/pdf_tool_flows.dart';
import 'pdf_reader_screen.dart';
import 'text_from_image_screen.dart';

/// Picks PDFs from the phone and adds them to the library.
Future<List<DocFile>> browsePdfs(BuildContext context) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
    return [for (final f in picked) await library.importBytes(f.name, await f.readAsBytes())];
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open the file: $e')));
    return const [];
  }
}

/// Merge, split, organize, compress, lock, unlock and OCR tools.
class PdfToolsScreen extends StatelessWidget {
  const PdfToolsScreen({super.key});

  Future<DocFile?> _pickOne(BuildContext context, String title) async {
    final picked = await pickLibraryPdfs(context, title: title, browse: () => browsePdfs(context));
    return picked == null || picked.isEmpty ? null : picked.first;
  }

  Future<void> _open(BuildContext context, DocFile? file, {String? password}) async {
    if (file == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PdfReaderScreen(file: file, password: password)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget tool(String label, String detail, IconData icon, Color color, Key key, Future<void> Function() onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassPanel(
            radius: 20,
            child: ListTile(
              key: key,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: color.withValues(alpha: 0.45)),
                ),
                child: Icon(icon, color: color, size: 21),
              ),
              title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(detail, style: TextStyle(fontSize: 12, color: p.textMuted)),
              onTap: onTap,
            ),
          ),
        );
    const violet = Color(0xFFA78BFA);
    const cyan = Color(0xFF67E8F9);
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('PDF tools')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          children: [
            tool('Merge PDFs', 'Join several files into one', Icons.merge_type_rounded, FileColors.pdf, const Key('tool-merge'), () async {
              final files = await pickLibraryPdfs(context, title: 'Merge PDFs', multiple: true, browse: () => browsePdfs(context));
              if (files == null || files.length < 2 || !context.mounted) return;
              final merged = await mergeFiles(context, files);
              if (context.mounted) await _open(context, merged);
            }),
            tool('Split a PDF', 'Save page ranges as separate files', Icons.call_split_rounded, FileColors.pdf, const Key('tool-split'), () async {
              final file = await _pickOne(context, 'Split which PDF?');
              if (file == null || !context.mounted) return;
              await splitFile(context, file);
            }),
            tool('Organize pages', 'Reorder, turn or remove pages', Icons.view_agenda_outlined, FileColors.pdf, const Key('tool-organize'), () async {
              final file = await _pickOne(context, 'Organize which PDF?');
              if (file == null || !context.mounted) return;
              final change = await organizeFile(context, file);
              if (change != null && context.mounted) await _open(context, change.file, password: change.password);
            }),
            tool('Make smaller', 'Shrink pictures for email and sharing', Icons.compress_rounded, violet, const Key('tool-compress'), () async {
              final file = await _pickOne(context, 'Make which PDF smaller?');
              if (file == null || !context.mounted) return;
              final smaller = await compressFile(context, file);
              if (smaller != null && context.mounted) await _open(context, smaller.file, password: smaller.password);
            }),
            tool('Add a password', 'Lock a PDF with AES-256', Icons.lock_outline_rounded, violet, const Key('tool-lock'), () async {
              final file = await _pickOne(context, 'Lock which PDF?');
              if (file == null || !context.mounted) return;
              await lockFile(context, file);
            }),
            tool('Remove a password', 'Unlock a PDF you have the password for', Icons.lock_open_rounded, violet, const Key('tool-unlock'), () async {
              final file = await _pickOne(context, 'Unlock which PDF?');
              if (file == null || !context.mounted) return;
              await unlockFile(context, file);
            }),
            tool('Make a scan searchable', 'Find and copy the text in scanned pages', Icons.manage_search_rounded, cyan, const Key('tool-searchable'), () async {
              final file = await _pickOne(context, 'Which scanned PDF?');
              if (file == null || !context.mounted) return;
              final change = await makeSearchable(context, file);
              if (change != null && context.mounted) await _open(context, change.file, password: change.password);
            }),
            tool('Text from pictures', 'Copy the words in a photo or scan', Icons.text_snippet_outlined, cyan, const Key('tool-ocr'),
                () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TextFromImageScreen()))),
            tool('Blank PDF page', 'An empty page to write, draw or sign on', Icons.note_add_outlined, FileColors.pdf, const Key('tool-blank'),
                () async => createFromTemplate(context, newTemplates.firstWhere((t) => t.kind == NewKind.pdf))),
          ],
        ),
      ),
    );
  }
}
