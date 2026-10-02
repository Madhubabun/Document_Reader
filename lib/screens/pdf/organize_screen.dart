import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../models/doc_file.dart';
import '../../services/pdf_tools.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';

/// Reorder, turn and remove pages. Pops with the plan, or null.
class OrganizeScreen extends StatefulWidget {
  const OrganizeScreen({super.key, required this.file, required this.source});

  final DocFile file;
  final PdfSource source;

  @override
  State<OrganizeScreen> createState() => _OrganizeScreenState();
}

class _Entry {
  _Entry(this.page);

  final int page;
  int turns = 0;
}

class _OrganizeScreenState extends State<OrganizeScreen> {
  PdfDocument? _doc;
  Object? _error;
  List<_Entry> _entries = [];

  /// The order and turns as opened, to tell whether anything changed.
  bool get _changed {
    if (_doc == null) return false;
    if (_entries.length != _doc!.pages.length) return true;
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].page != i + 1 || _entries[i].turns % 4 != 0) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final doc = await openPdfData(widget.source.bytes, widget.source.password);
      if (!mounted) {
        await doc.dispose();
        return;
      }
      setState(() {
        _doc = doc;
        _entries = [for (final p in doc.pages) _Entry(p.pageNumber)];
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _doc?.dispose();
    super.dispose();
  }

  Future<bool> _confirmDiscard() async {
    if (!_changed) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard the changes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final doc = _doc;
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) navigator.pop();
      },
      child: Scaffold(
        backgroundColor: p.background,
        appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Organize pages')),
        body: SafeArea(
          top: false,
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('This PDF could not be opened.\n$_error', textAlign: TextAlign.center)))
              : doc == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: Text('Drag to reorder. Turn or remove pages, then save.', style: TextStyle(color: p.textMuted, fontSize: 13)),
                        ),
                        Expanded(
                          child: ReorderableListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            buildDefaultDragHandles: false,
                            itemCount: _entries.length,
                            onReorderItem: (from, to) => setState(() => _entries.insert(to, _entries.removeAt(from))),
                            itemBuilder: (context, i) {
                              final e = _entries[i];
                              final page = doc.pages[e.page - 1];
                              final rotation = PdfPageRotation.values[(page.rotation.index + e.turns) % 4];
                              return Padding(
                                key: ObjectKey(e),
                                padding: const EdgeInsets.only(bottom: 10),
                                child: GlassPanel(
                                  radius: 18,
                                  padding: const EdgeInsets.all(8),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 74,
                                        height: 96,
                                        child: PdfPageView(document: doc, pageNumber: e.page, rotationOverride: rotation, maximumDpi: 72, backgroundColor: Colors.white),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text('Page ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                                            if (e.page != i + 1) Text('was page ${e.page}', style: TextStyle(fontSize: 12, color: p.textMuted)),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Turn page ${i + 1}',
                                        onPressed: () => setState(() => e.turns = (e.turns + 1) % 4),
                                        icon: const Icon(Icons.rotate_right_rounded),
                                      ),
                                      IconButton(
                                        tooltip: 'Remove page ${i + 1}',
                                        onPressed: _entries.length == 1 ? null : () => setState(() => _entries.removeAt(i)),
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
                            key: const Key('organize-save'),
                            label: 'Save · ${_entries.length} ${_entries.length == 1 ? 'page' : 'pages'}',
                            icon: Icons.check_rounded,
                            onPressed: !_changed ? null : () => Navigator.pop(context, [for (final e in _entries) PagePlan(e.page, quarterTurns: e.turns)]),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}
