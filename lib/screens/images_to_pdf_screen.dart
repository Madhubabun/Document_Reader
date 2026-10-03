import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/error_text.dart';
import '../services/images_to_pdf.dart';
import '../services/library_store.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'pdf_reader_screen.dart';

/// Puts pictures (from the gallery, the scanner or another app) in order
/// and makes a PDF of them.
class ImagesToPdfScreen extends StatefulWidget {
  const ImagesToPdfScreen({super.key, this.initial = const [], this.scanned = false});

  final List<Uint8List> initial;

  /// Scans are already cropped to the page, so they default to pages shaped
  /// like the scan, with no margins.
  final bool scanned;

  /// Adds [pictures] to the open screen, when it is the one showing.
  /// Returns false when there is none.
  static bool addToOpen(List<Uint8List> pictures) {
    final open = _ImagesToPdfScreenState._showing;
    if (open == null || !open.mounted || open._busy || !(ModalRoute.of(open.context)?.isCurrent ?? false)) return false;
    open._append([for (final bytes in pictures) _Item(PageImage(bytes))]);
    return true;
  }

  @override
  State<ImagesToPdfScreen> createState() => _ImagesToPdfScreenState();
}

class _Item {
  _Item(this.image);

  final key = UniqueKey();
  PageImage image;
}

String _stamp(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.day} ${months[d.month - 1]} ${d.year} ${two(d.hour)}.${two(d.minute)}';
}

class _ImagesToPdfScreenState extends State<ImagesToPdfScreen> {
  late final _items = [for (final bytes in widget.initial) _Item(PageImage(bytes))];
  late PageSizeChoice _size = widget.scanned ? PageSizeChoice.fit : PageSizeChoice.a4;
  late bool _margins = !widget.scanned;
  bool _smaller = false;
  bool _busy = false;
  bool _picking = false;
  late final _name = TextEditingController(text: '${widget.scanned ? 'Scan' : 'Photos'} ${_stamp(DateTime.now())}');

  static _ImagesToPdfScreenState? _showing;

  @override
  void initState() {
    super.initState();
    _showing = this;
    if (_items.isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _add());
  }

  @override
  void dispose() {
    if (_showing == this) _showing = null;
    _name.dispose();
    super.dispose();
  }

  void _append(List<_Item> added) => setState(() => _items.addAll(added));

  Future<void> _add() async {
    if (_picking || _busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _picking = true);
    try {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      final added = <_Item>[];
      for (final file in picked) {
        added.add(_Item(PageImage(await file.readAsBytes())));
      }
      if (mounted) _append(added);
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Could not open your pictures. ${errorText(e)}')));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _create() async {
    if (_items.isEmpty || _busy) return;
    final library = AppScope.of(context).library;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final name = safeBaseName(_name.text, fallback: widget.scanned ? 'Scan' : 'Photos', extension: 'pdf');
      final bytes = await imagesToPdf([for (final i in _items) i.image], size: _size, margins: _margins, smaller: _smaller, title: name);
      final saved = await library.importBytes('$name.pdf', bytes);
      if (!mounted) return;
      navigator.pushReplacement(MaterialPageRoute<void>(builder: (_) => PdfReaderScreen(file: saved)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not make the PDF. ${errorText(e)}')));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(widget.scanned ? 'Scanned pages' : 'Pictures to PDF'),
        actions: [
          IconButton(tooltip: 'Add pictures', onPressed: _busy || _picking ? null : _add, icon: const Icon(Icons.add_photo_alternate_outlined)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                buildDefaultDragHandles: false,
                header: _Options(
                  name: _name,
                  size: _size,
                  margins: _margins,
                  smaller: _smaller,
                  onSize: (v) => setState(() => _size = v),
                  onMargins: (v) => setState(() => _margins = v),
                  onSmaller: (v) => setState(() => _smaller = v),
                ),
                footer: _items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(top: 30),
                        child: Column(
                          children: [
                            Icon(Icons.photo_library_outlined, size: 44, color: p.textMuted),
                            const SizedBox(height: 10),
                            Text('Add the pictures you want in the PDF.', style: TextStyle(color: p.textMuted)),
                            const SizedBox(height: 14),
                            OutlinedButton.icon(onPressed: _picking ? null : _add, icon: const Icon(Icons.add_rounded), label: const Text('Add pictures')),
                          ],
                        ),
                      )
                    : null,
                itemCount: _items.length,
                onReorderItem: (from, to) => setState(() => _items.insert(to, _items.removeAt(from))),
                itemBuilder: (context, i) {
                  final item = _items[i];
                  return Padding(
                    key: item.key,
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassPanel(
                      radius: 18,
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 74,
                              height: 96,
                              color: Colors.white,
                              child: RotatedBox(
                                quarterTurns: item.image.quarterTurns,
                                child: Image.memory(
                                  item.image.bytes,
                                  cacheWidth: 240,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) => const Icon(Icons.image_outlined, color: Colors.black38),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(child: Text('Page ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                          IconButton(
                            tooltip: 'Turn page ${i + 1}',
                            onPressed: _busy ? null : () => setState(() => item.image = item.image.turned()),
                            icon: const Icon(Icons.rotate_right_rounded),
                          ),
                          IconButton(
                            tooltip: 'Remove page ${i + 1}',
                            onPressed: _busy ? null : () => setState(() => _items.removeAt(i)),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(Icons.drag_handle_rounded, color: p.textMuted, semanticLabel: 'Drag to reorder'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: NeonButton(
                label: _busy
                    ? 'Making the PDF…'
                    : _items.isEmpty
                        ? 'Create PDF'
                        : 'Create PDF · ${_items.length} ${_items.length == 1 ? 'page' : 'pages'}',
                icon: Icons.picture_as_pdf_outlined,
                onPressed: _items.isEmpty || _busy ? null : _create,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Options extends StatelessWidget {
  const _Options({
    required this.name,
    required this.size,
    required this.margins,
    required this.smaller,
    required this.onSize,
    required this.onMargins,
    required this.onSmaller,
  });

  final TextEditingController name;
  final PageSizeChoice size;
  final bool margins;
  final bool smaller;
  final ValueChanged<PageSizeChoice> onSize;
  final ValueChanged<bool> onMargins;
  final ValueChanged<bool> onSmaller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GlassPanel(
        radius: 20,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('pdf-name'),
              controller: name,
              decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf'),
            ),
            const SizedBox(height: 12),
            Text('Page size', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.textMuted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in PageSizeChoice.values) GlassChip(label: s.label, selected: s == size, onTap: () => onSize(s)),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: margins,
              onChanged: onMargins,
              title: const Text('White border', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: smaller,
              onChanged: onSmaller,
              title: const Text('Smaller file', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('Shrinks big photos. Still sharp on screen and in print.', style: TextStyle(fontSize: 12, color: p.textMuted)),
            ),
          ],
        ),
      ),
    );
  }
}
