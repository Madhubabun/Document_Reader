import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../screens/office_reader_screen.dart';
import '../screens/pdf_reader_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

const supportedExtensions = ['pdf', 'docx', 'doc', 'xlsx', 'xls', 'pptx', 'ppt'];

/// Picks one or more documents, copies them into the library and opens the
/// first one. Returns the imported files.
Future<List<DocFile>> importDocuments(BuildContext context, {bool openFirst = true}) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final List<PlatformFile> picked;
  try {
    picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: supportedExtensions);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open the file picker: $e')));
    return const [];
  }
  final imported = <DocFile>[];
  for (final file in picked) {
    try {
      imported.add(await library.importBytes(file.name, await file.readAsBytes()));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text('Could not import ${file.name}')));
    }
  }
  if (openFirst && imported.isNotEmpty && context.mounted) {
    await openDocument(context, imported.first);
  }
  return imported;
}

Future<void> openDocument(BuildContext context, DocFile file) async {
  final library = AppScope.of(context).library;
  await library.markOpened(file);
  if (!context.mounted) return;
  if (file.isLegacyBinary) {
    await _explainLegacy(context, file);
    return;
  }
  final Widget screen = switch (file.kind) {
    DocKind.pdf => PdfReaderScreen(file: file),
    DocKind.word || DocKind.excel || DocKind.powerpoint => OfficeReaderScreen(file: file),
    DocKind.other => const SizedBox.shrink(),
  };
  if (file.kind == DocKind.other) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
}

Future<void> shareDocument(DocFile file) async {
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: file.name));
}

Future<void> _explainLegacy(BuildContext context, DocFile file) {
  final modern = '${file.extension}x';
  return showGlassSheet<void>(
    context,
    (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          FileTypeBadge(kind: file.kind, size: 40),
          const SizedBox(width: 14),
          Expanded(child: Text(file.name, style: Theme.of(context).textTheme.titleMedium)),
        ]),
        const SizedBox(height: 16),
        Text(
          'This is an older .${file.extension} file from Office 97–2003. '
          'Previewing this format is coming soon. Saving it as .$modern in Office, then importing it again, opens it here today.',
          style: TextStyle(color: context.palette.textMuted, height: 1.45),
        ),
        const SizedBox(height: 20),
        NeonButton(label: 'Got it', onPressed: () => Navigator.pop(context)),
      ],
    ),
  );
}

/// Placeholder sheet for features that are designed but not built yet.
Future<void> showComingSoon(BuildContext context, String feature, String detail) {
  return showGlassSheet<void>(
    context,
    (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(feature, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        Text(detail, style: TextStyle(color: context.palette.textMuted, height: 1.45)),
        const SizedBox(height: 20),
        NeonButton(label: 'Okay', onPressed: () => Navigator.pop(context)),
      ],
    ),
  );
}
