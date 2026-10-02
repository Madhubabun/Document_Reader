import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/reader_chrome.dart';

/// Immersive PDF reader: tap the page to show or hide the floating glass bars.
class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key, required this.file});

  final DocFile file;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final _controller = PdfViewerController();
  late final PdfTextSearcher _searcher = PdfTextSearcher(_controller)..addListener(_onSearchChanged);
  final _searchField = TextEditingController();
  PdfDocument? _document;
  int _page = 1;
  bool _chrome = true;
  bool _searching = false;

  @override
  void dispose() {
    _searcher.removeListener(_onSearchChanged);
    _searcher.dispose();
    _searchField.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  Future<String?> _askPassword() {
    final field = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Password protected'),
        content: TextField(
          controller: field,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text), child: const Text('Unlock')),
        ],
      ),
    ).whenComplete(field.dispose);
  }

  Future<void> _showContents() async {
    final doc = _document;
    if (doc == null) return;
    final outline = await doc.loadOutline();
    if (!mounted) return;
    final flat = <(int, PdfOutlineNode)>[];
    void walk(List<PdfOutlineNode> nodes, int depth) {
      for (final n in nodes) {
        flat.add((depth, n));
        walk(n.children, depth + 1);
      }
    }

    walk(outline, 0);
    final page = await showGlassSheet<int>(context, (sheet) {
      final p = sheet.palette;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Contents', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 10),
          if (flat.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('This PDF has no table of contents. Jump to a page instead:', style: TextStyle(color: p.textMuted)),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.55),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (depth, node) in flat)
                  ListTile(
                    contentPadding: EdgeInsets.only(left: 16.0 * depth),
                    title: Text(node.title, style: TextStyle(fontWeight: depth == 0 ? FontWeight.w700 : FontWeight.w500)),
                    trailing: node.dest == null ? null : Text('${node.dest!.pageNumber}', style: TextStyle(color: p.textMuted)),
                    onTap: node.dest == null ? null : () => Navigator.pop(sheet, node.dest!.pageNumber),
                  ),
                if (flat.isEmpty)
                  for (var i = 1; i <= doc.pages.length; i++)
                    ListTile(title: Text('Page $i'), onTap: () => Navigator.pop(sheet, i)),
              ],
            ),
          ),
        ],
      );
    });
    if (page != null) await _controller.goToPage(pageNumber: page);
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      _chrome = true;
      if (!_searching) {
        _searchField.clear();
        _searcher.resetTextSearch();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final p = context.palette;
    final pages = _document?.pages.length;
    return Scaffold(
      backgroundColor: p.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListenableBuilder(
              listenable: settings,
              builder: (context, child) {
                final filter = pageToneFilter(settings.pageTone);
                return filter == null ? child! : ColorFiltered(colorFilter: filter, child: child);
              },
              child: PdfViewer.file(
                widget.file.path,
                controller: _controller,
                passwordProvider: _askPassword,
                params: PdfViewerParams(
                  backgroundColor: p.background,
                  margin: 14,
                  boundaryMargin: const EdgeInsets.only(top: 120, bottom: 140),
                  pageDropShadow: BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 30, offset: const Offset(0, 14)),
                  pagePaintCallbacks: [_searcher.pageTextMatchPaintCallback],
                  onViewerReady: (document, controller) => setState(() => _document = document),
                  onPageChanged: (page) {
                    if (page != null) setState(() => _page = page);
                  },
                  onGeneralTap: (context, controller, details) {
                    if (details.type == PdfViewerGeneralTapType.tap && details.tapOn == PdfViewerPart.background) {
                      setState(() => _chrome = !_chrome);
                    }
                    return false;
                  },
                  errorBannerBuilder: (context, error, stackTrace, documentRef) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('This PDF could not be opened.\n$error', textAlign: TextAlign.center, style: TextStyle(color: p.textMuted)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            top: _chrome ? 0 : -140,
            child: Column(
              children: [
                ReaderTopBar(
                  title: widget.file.name,
                  subtitle: pages == null ? 'Opening…' : 'Page $_page of $pages',
                  actions: [
                    IconButton(tooltip: 'Share', onPressed: () => shareDocument(widget.file), icon: const Icon(Icons.ios_share_rounded, size: 21)),
                  ],
                ),
                if (_searching) _SearchBar(controller: _searchField, searcher: _searcher, onClose: _toggleSearch),
              ],
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            bottom: _chrome ? 0 : -140,
            child: ReaderDock(actions: [
              DockAction(Icons.format_list_bulleted_rounded, 'Contents', _showContents),
              DockAction(Icons.search_rounded, 'Search', _toggleSearch, active: _searching),
              DockAction(Icons.edit_outlined, 'Annotate', () {
                showComingSoon(context, 'Annotate PDFs', 'Highlight, underline, draw and sign are being built next, in a translucent tool panel.');
              }),
              DockAction(Icons.contrast_rounded, 'Page', () => showPageToneSheet(context, settings)),
              DockAction(Icons.ios_share_rounded, 'Share', () => shareDocument(widget.file)),
            ]),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.searcher, required this.onClose});

  final TextEditingController controller;
  final PdfTextSearcher searcher;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final count = searcher.matches.length;
    final index = searcher.currentIndex;
    final status = searcher.isSearching
        ? 'Searching…'
        : controller.text.isEmpty
            ? ''
            : count == 0
                ? 'No matches'
                : '${(index ?? 0) + 1} of $count';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: GlassPanel(
        strong: true,
        radius: 20,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.search_rounded, color: p.textMuted),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (v) => searcher.startTextSearch(v),
                onSubmitted: (_) => searcher.goToNextMatch(),
                decoration: const InputDecoration(hintText: 'Find in document', border: InputBorder.none, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 14)),
              ),
            ),
            Text(status, style: TextStyle(fontSize: 12, color: p.textMuted, fontWeight: FontWeight.w600)),
            IconButton(tooltip: 'Previous match', onPressed: count == 0 ? null : searcher.goToPrevMatch, icon: const Icon(Icons.keyboard_arrow_up_rounded)),
            IconButton(tooltip: 'Next match', onPressed: count == 0 ? null : searcher.goToNextMatch, icon: const Icon(Icons.keyboard_arrow_down_rounded)),
            IconButton(tooltip: 'Close search', onPressed: onClose, icon: const Icon(Icons.close_rounded)),
          ],
        ),
      ),
    );
  }
}
