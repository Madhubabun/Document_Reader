import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../models/doc_file.dart';
import '../../services/error_text.dart';
import '../../services/library_store.dart';
import '../../services/ocr.dart';
import '../../services/pdf_edits.dart';
import '../../services/pdf_tools.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import 'organize_screen.dart';

/// Shows a spinner with [label] while [work] runs. [work] can change the
/// label as it goes. The user can't dismiss it.
Future<T> runWithProgress<T>(BuildContext context, String label, Future<T> Function(ValueSetter<String> update) work) async {
  final text = ValueNotifier(label);
  final navigator = Navigator.of(context, rootNavigator: true);
  // Kept so the spinner, and only the spinner, is closed afterwards, even
  // if another screen opened on top of it meanwhile.
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 18),
            Expanded(child: ValueListenableBuilder(valueListenable: text, builder: (_, v, _) => Text(v, key: const Key('progress-text')))),
          ],
        ),
      ),
    ),
  );
  navigator.push(route);
  try {
    return await work((v) => text.value = v);
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    // Let the dialog finish closing before the notifier goes.
    WidgetsBinding.instance.addPostFrameCallback((_) => text.dispose());
  }
}

/// Asks for a password. With [confirm], asks twice and checks they match.
Future<String?> showPasswordDialog(BuildContext context, {required String title, String? message, String action = 'OK', bool confirm = false}) {
  return showDialog<String>(context: context, builder: (_) => _PasswordDialog(title: title, message: message, action: action, confirm: confirm));
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.title, required this.message, required this.action, required this.confirm});

  final String title;
  final String? message;
  final String action;
  final bool confirm;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    if (_first.text.isEmpty) {
      setState(() => _error = 'Type a password.');
      return;
    }
    if (widget.confirm && _first.text != _second.text) {
      setState(() => _error = 'The two passwords are different.');
      return;
    }
    Navigator.pop(context, _first.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!, style: TextStyle(color: context.palette.textMuted, fontSize: 13, height: 1.35)),
            const SizedBox(height: 10),
          ],
          TextField(
            key: const Key('password'),
            controller: _first,
            obscureText: _hidden,
            autofocus: true,
            textInputAction: widget.confirm ? TextInputAction.next : TextInputAction.done,
            onSubmitted: widget.confirm ? null : (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: _hidden ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              ),
            ),
          ),
          if (widget.confirm)
            TextField(
              key: const Key('password-again'),
              controller: _second,
              obscureText: _hidden,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Type it again'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('password-ok'), onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

/// Reads [file] and, when it has a password, asks for it until it is right
/// (trying [known] first). Null when the user gives up.
Future<PdfSource?> openSource(BuildContext context, DocFile file, {String? known}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    return await _openSource(context, file, known);
  } catch (e) {
    _say(messenger, '${file.name} could not be opened. ${_reason(e)}');
    return null;
  }
}

Future<PdfSource?> _openSource(BuildContext context, DocFile file, String? known) async {
  final bytes = await File(file.path).readAsBytes();
  if (!await needsPassword(bytes)) return PdfSource(bytes);
  if (known != null && await passwordOpens(bytes, known)) return PdfSource(bytes, password: known);
  String? message = '${file.name} is password protected.';
  while (true) {
    if (!context.mounted) return null;
    final password = await showPasswordDialog(context, title: 'Enter the password', message: message, action: 'Open');
    if (password == null || !context.mounted) return null;
    if (await passwordOpens(bytes, password)) return PdfSource(bytes, password: password);
    message = 'That password is not right. Try again.';
  }
}

String _reason(Object e) => errorText(e);

void _say(ScaffoldMessengerState messenger, String text) => messenger.showSnackBar(SnackBar(content: Text(text)));

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _base(DocFile file) => file.name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');

/// The result of a tool that changed the file itself.
typedef ToolChange = ({DocFile file, String? password});

/// Reorders, turns and removes pages, replacing the file (the previous
/// version is kept).
Future<ToolChange?> organizeFile(BuildContext context, DocFile file, {String? password}) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final source = await openSource(context, file, known: password);
  if (source == null || !context.mounted) return null;
  final plan = await navigator.push<List<PagePlan>>(MaterialPageRoute(builder: (_) => OrganizeScreen(file: file, source: source)));
  if (plan == null || !context.mounted) return null;
  try {
    final updated = await runWithProgress(context, 'Saving the pages…', (_) async => library.saveEdited(file, await organizePdf(source, plan)));
    _say(messenger, 'Pages saved. The previous version is kept as a backup.');
    return (file: updated, password: source.password);
  } catch (e) {
    _say(messenger, 'Could not save the pages. ${_reason(e)}');
    return null;
  }
}

/// Adds a password (or changes it), replacing the file. Earlier versions
/// are deleted so no unprotected copy stays in the app.
Future<ToolChange?> lockFile(BuildContext context, DocFile file, {String? password}) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final source = await openSource(context, file, known: password);
  if (source == null || !context.mounted) return null;
  final newPassword = await showPasswordDialog(
    context,
    title: source.password == null ? 'Add a password' : 'Change the password',
    message: 'Anyone opening this PDF will need the password. It cannot be recovered if you forget it.',
    action: 'Lock',
    confirm: true,
  );
  if (newPassword == null || !context.mounted) return null;
  try {
    final updated = await runWithProgress(context, 'Locking the PDF…', (_) async => library.saveEdited(file, await lockPdf(source, newPassword), dropHistory: true));
    _say(messenger, 'Locked with AES-256. It opens in any PDF app with the password.');
    return (file: updated, password: newPassword);
  } catch (e) {
    _say(messenger, 'Could not lock the PDF. ${_reason(e)}');
    return null;
  }
}

/// Removes the password, replacing the file.
Future<ToolChange?> unlockFile(BuildContext context, DocFile file, {String? password}) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (!await needsPassword(await File(file.path).readAsBytes())) {
      _say(messenger, 'This PDF has no password.');
      return null;
    }
  } catch (e) {
    _say(messenger, 'Could not open the PDF. ${_reason(e)}');
    return null;
  }
  if (!context.mounted) return null;
  final source = await openSource(context, file, known: password);
  if (source == null || !context.mounted) return null;
  try {
    final updated = await runWithProgress(context, 'Removing the password…', (_) async => library.saveEdited(file, await unlockPdf(source)));
    _say(messenger, 'Password removed. The locked version is kept as a backup.');
    return (file: updated, password: null);
  } catch (e) {
    _say(messenger, 'Could not remove the password. ${_reason(e)}');
    return null;
  }
}

/// Adds an invisible text layer to scanned pages so they can be searched
/// and copied from, replacing the file.
Future<ToolChange?> makeSearchable(BuildContext context, DocFile file, {String? password}) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final source = await openSource(context, file, known: password);
  if (source == null || !context.mounted) return null;
  final reader = TextReader();
  try {
    final edits = await runWithProgress(context, 'Reading the pages…', (update) async {
      final doc = await openPdfData(source.bytes, source.password);
      try {
        return await reader.readScannedPages(doc, onPage: (page, count) => update('Reading page $page of $count…'));
      } finally {
        await doc.dispose();
      }
    });
    if (edits.isEmpty) {
      _say(messenger, 'No scanned text found. Pages that already have text are searchable as they are.');
      return null;
    }
    if (!context.mounted) return null;
    final updated = await runWithProgress(
        context, 'Saving…', (_) async => library.saveEdited(file, await applyPdfEdits(source.bytes, edits, password: source.password, unicodeFont: await _unicodeFontFor(edits))));
    _say(messenger, 'Text added to ${edits.length} ${edits.length == 1 ? 'page' : 'pages'}. You can now search and copy it.');
    return (file: updated, password: source.password);
  } catch (e) {
    _say(messenger, 'Could not read the text. ${_reason(e)}');
    return null;
  } finally {
    await reader.close();
  }
}

/// Carlito (metric-compatible with Calibri, with Latin Extended letters),
/// only when some recognised line needs more than Helvetica's Windows-1252.
Future<Uint8List?> _unicodeFontFor(List<TextLayerEdit> edits) async {
  final needed = edits.any((e) => e.lines.any((l) => !fitsWinAnsi(l.text)));
  if (!needed) return null;
  final data = await rootBundle.load('assets/fonts/office/Carlito-normal-400.ttf');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Saves a smaller copy and returns it with its password (a smaller copy
/// keeps the original's).
Future<ToolChange?> compressFile(BuildContext context, DocFile file, {String? password}) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final source = await openSource(context, file, known: password);
  if (source == null || !context.mounted) return null;
  final level = await showGlassSheet<CompressLevel>(
    context,
    (sheet) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Make it smaller', style: Theme.of(sheet).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('Pictures are shrunk; text stays sharp. A copy is saved and the original is kept.',
            style: TextStyle(fontSize: 12, color: sheet.palette.textMuted)),
        const SizedBox(height: 8),
        for (final l in CompressLevel.values)
          ListTile(
            key: Key('compress-${l.name}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(l.label, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(l.detail, style: TextStyle(fontSize: 12, color: sheet.palette.textMuted)),
            onTap: () => Navigator.pop(sheet, l),
          ),
      ],
    ),
  );
  if (level == null || !context.mounted) return null;
  try {
    final result = await runWithProgress(context, 'Shrinking the pictures…', (_) => compressPdf(source, level));
    if (result.imagesChanged == 0) {
      _say(messenger, result.pagesSkipped > 0
          ? 'This PDF could not be made smaller without changing how it looks.'
          : 'This PDF is already compact. It has no large pictures to shrink.');
      return null;
    }
    final saved = await library.importBytes('${_base(file)} (smaller).pdf', result.bytes);
    _say(messenger, '${formatSize(source.bytes.length)} → ${formatSize(result.bytes.length)}. Saved as ${saved.name}.');
    return (file: saved, password: source.password);
  } catch (e) {
    _say(messenger, 'Could not make it smaller. ${_reason(e)}');
    return null;
  }
}

/// Parses "1-3, 5, 7-" into groups of page numbers within [count]. Throws a
/// [FormatException] with a message to show.
List<List<int>> parseRanges(String text, int count) {
  final groups = <List<int>>[];
  for (final raw in text.split(RegExp(r'[,;]'))) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final m = RegExp(r'^(\d+)?\s*(?:[-–]\s*(\d+)?)?$').firstMatch(part);
    if (m == null || (m.group(1) == null && m.group(2) == null)) throw FormatException('"$part" is not a page or range.');
    final dash = part.contains(RegExp('[-–]'));
    final from = int.parse(m.group(1) ?? '1');
    final to = m.group(2) != null ? int.parse(m.group(2)!) : (dash ? count : from);
    if (from < 1 || to < 1 || from > count || to > count) throw FormatException('This PDF has $count pages.');
    if (from > to) throw FormatException('"$part" runs backwards.');
    groups.add([for (var p = from; p <= to; p++) p]);
  }
  if (groups.isEmpty) throw const FormatException('Type the pages for each file, like 1-3, 4-6.');
  return groups;
}

/// Splits the file into several and returns the new files.
Future<List<DocFile>> splitFile(BuildContext context, DocFile file, {String? password}) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final source = await openSource(context, file, known: password);
  if (source == null || !context.mounted) return const [];
  final int count;
  try {
    final doc = await openPdfData(source.bytes, source.password);
    try {
      count = doc.pages.length;
    } finally {
      await doc.dispose();
    }
  } catch (e) {
    _say(messenger, 'Could not open the PDF. ${_reason(e)}');
    return const [];
  }
  if (!context.mounted) return const [];
  if (count < 2) {
    _say(messenger, 'This PDF has only one page.');
    return const [];
  }
  final groups = await showDialog<List<List<int>>>(context: context, builder: (_) => _SplitDialog(count: count));
  if (groups == null || !context.mounted) return const [];
  try {
    final files = await runWithProgress(context, 'Splitting…', (_) async {
      final parts = await splitPdf(source, groups);
      final saved = <DocFile>[];
      for (var i = 0; i < parts.length; i++) {
        final g = groups[i];
        final label = g.length == 1 ? 'page ${g.first}' : 'pages ${g.first}-${g.last}';
        saved.add(await library.importBytes('${_base(file)} ($label).pdf', parts[i]));
      }
      return saved;
    });
    _say(messenger, 'Saved ${files.length} PDFs to your files${source.password == null ? '' : ' (without the password)'}.');
    return files;
  } catch (e) {
    _say(messenger, 'Could not split the PDF. ${_reason(e)}');
    return const [];
  }
}

class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.count});

  final int count;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  bool _everyPage = false;
  late final _ranges = TextEditingController(text: '1-${(widget.count / 2).ceil()}, ${(widget.count / 2).ceil() + 1}-${widget.count}');
  String? _error;

  @override
  void dispose() {
    _ranges.dispose();
    super.dispose();
  }

  void _submit() {
    if (_everyPage) {
      Navigator.pop(context, [
        for (var p = 1; p <= widget.count; p++) [p],
      ]);
      return;
    }
    try {
      Navigator.pop(context, parseRanges(_ranges.text, widget.count));
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Split into files'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            key: const Key('split-every'),
            contentPadding: EdgeInsets.zero,
            value: _everyPage,
            onChanged: (v) => setState(() => _everyPage = v),
            title: Text('Each of the ${widget.count} pages on its own'),
          ),
          if (!_everyPage)
            TextField(
              key: const Key('split-ranges'),
              controller: _ranges,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(labelText: 'Pages for each file', helperText: 'For example 1-3, 4, 5-${widget.count}', errorText: _error),
              onSubmitted: (_) => _submit(),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('split-ok'), onPressed: _submit, child: const Text('Split')),
      ],
    );
  }
}

/// Lets the user pick PDFs from the library (or browse the phone).
Future<List<DocFile>?> pickLibraryPdfs(BuildContext context, {required String title, bool multiple = false, required Future<List<DocFile>> Function() browse}) {
  return showGlassSheet<List<DocFile>>(context, (sheet) => _PdfPicker(title: title, multiple: multiple, browse: browse));
}

class _PdfPicker extends StatefulWidget {
  const _PdfPicker({required this.title, required this.multiple, required this.browse});

  final String title;
  final bool multiple;
  final Future<List<DocFile>> Function() browse;

  @override
  State<_PdfPicker> createState() => _PdfPickerState();
}

class _PdfPickerState extends State<_PdfPicker> {
  final _picked = <DocFile>[];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final library = AppScope.of(context).library;
    final pdfs = library.files.where((f) => f.kind == DocKind.pdf && File(f.path).existsSync()).toList();
    return Flexible(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          if (widget.multiple) Text('Tap the files in the order you want them.', style: TextStyle(fontSize: 12, color: p.textMuted)),
          const SizedBox(height: 8),
          Flexible(
            child: pdfs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('No PDFs in your files yet.', textAlign: TextAlign.center, style: TextStyle(color: p.textMuted)),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final f in pdfs)
                        ListTile(
                          key: ValueKey('pick-${f.path}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                          leading: const FileTypeBadge(kind: DocKind.pdf, size: 36),
                          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(formatSize(f.sizeBytes), style: TextStyle(fontSize: 12, color: p.textMuted)),
                          trailing: widget.multiple && _picked.contains(f)
                              ? CircleAvatar(radius: 13, backgroundColor: p.accent, child: Text('${_picked.indexOf(f) + 1}', style: const TextStyle(fontSize: 12, color: Colors.black)))
                              : null,
                          onTap: () {
                            if (!widget.multiple) {
                              Navigator.pop(context, [f]);
                              return;
                            }
                            setState(() => _picked.contains(f) ? _picked.remove(f) : _picked.add(f));
                          },
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    final added = await widget.browse();
                    if (added.isEmpty || !mounted) return;
                    if (!widget.multiple) {
                      navigator.pop([added.first]);
                      return;
                    }
                    setState(() => _picked.addAll(added.where((a) => !_picked.contains(a))));
                  },
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Browse phone'),
                ),
              ),
              if (widget.multiple) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const Key('pick-done'),
                    onPressed: _picked.length < 2 ? null : () => Navigator.pop(context, List.of(_picked)),
                    child: Text(_picked.length < 2 ? 'Pick 2 or more' : 'Use ${_picked.length}'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Merges [files] in order into a new file and returns it.
Future<DocFile?> mergeFiles(BuildContext context, List<DocFile> files) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final sources = <PdfSource>[];
  for (final f in files) {
    if (!context.mounted) return null;
    final s = await openSource(context, f);
    if (s == null) return null;
    sources.add(s);
  }
  if (!context.mounted) return null;
  final name = safeBaseName('${_base(files.first)} (merged)', fallback: 'Merged');
  try {
    final merged = await runWithProgress(context, 'Merging ${files.length} PDFs…', (_) async => library.importBytes('$name.pdf', await mergePdfs(sources)));
    final locked = sources.any((s) => s.password != null);
    _say(messenger, 'Merged into ${merged.name}${locked ? ' (without the passwords)' : ''}.');
    return merged;
  } catch (e) {
    _say(messenger, 'Could not merge. ${_reason(e)}');
    return null;
  }
}
