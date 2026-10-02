import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../services/pdf_signer.dart';
import '../services/signature_store.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/reader_chrome.dart';
import 'signature_pad_screen.dart';

/// Immersive PDF reader: tap the page to show or hide the floating glass bars.
class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key, required this.file});

  final DocFile file;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final _controller = PdfViewerController();
  // Created once the viewer has loaded the document: the searcher reads the
  // document from the controller as soon as it is constructed.
  PdfTextSearcher? _searcher;
  final _searchField = TextEditingController();
  PdfDocument? _document;
  int _page = 1;
  bool _chrome = true;
  bool _searching = false;

  /// The file as last saved (signing replaces it).
  late DocFile _file = widget.file;

  /// Bumped to reopen the viewer after the file changed.
  int _revision = 0;

  /// The password that opened the file, reused to reopen it after signing.
  String? _password;
  bool _passwordReused = false;

  /// The signature being placed, if any.
  final _placing = ValueNotifier<_Placement?>(null);
  bool _stamping = false;

  @override
  void dispose() {
    _searcher?.removeListener(_onSearchChanged);
    _searcher?.dispose();
    _searchField.dispose();
    _placing.value?.image.dispose();
    _placing.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  Future<String?> _providePassword() async {
    if (_password != null && !_passwordReused) {
      _passwordReused = true;
      return _password;
    }
    final password = await _askPassword();
    if (password != null) _password = password;
    return password;
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
        _searcher?.resetTextSearch();
      }
    });
  }

  /// Lets the user pick a saved signature or draw a new one, then shows it
  /// on the current page to drag into place.
  Future<void> _sign() async {
    final doc = _document;
    if (doc == null || _stamping) return;
    final store = AppScope.of(context).library.signatures;
    final png = await _pickSignature(store);
    if (png == null || !mounted) return;
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
    if (!mounted) {
      image.dispose();
      return;
    }
    final page = doc.pages[_page - 1];
    // Start 40% of the page wide, below the middle, keeping the drawing's shape.
    final aspect = image.height / image.width * page.width / page.height;
    var w = 0.4;
    var h = w * aspect;
    if (h > 0.25) {
      h = 0.25;
      w = h / aspect;
    }
    _placing.value?.image.dispose();
    _placing.value = _Placement(page: _page, rect: Rect.fromLTWH((1 - w) / 2, (0.72 - h / 2).clamp(0.0, 1 - h), w, h), image: image, rgba: rgba);
    setState(() {
      _chrome = true;
      if (_searching) _toggleSearch();
    });
  }

  Future<Uint8List?> _pickSignature(SignatureStore store) async {
    var saved = await store.list();
    if (!mounted) return null;
    return showGlassSheet<Uint8List>(context, (sheet) {
      final p = sheet.palette;
      return StatefulBuilder(
        builder: (sheet, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Sign', style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(saved.isEmpty ? 'Draw your signature once and it is kept on this phone for next time.' : 'Tap a signature to place it. Long-press to delete it.',
                style: TextStyle(color: p.textMuted)),
            const SizedBox(height: 14),
            for (final file in saved)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('saved-signature-${file.path}'),
                    onTap: () async {
                      final bytes = await file.readAsBytes();
                      if (sheet.mounted) Navigator.pop(sheet, bytes);
                    },
                    onLongPress: () async {
                      final ok = await showDialog<bool>(
                        context: sheet,
                        builder: (context) => AlertDialog(
                          title: const Text('Delete this signature?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok != true) return;
                      await store.delete(file);
                      saved = await store.list();
                      setSheet(() {});
                    },
                    child: SizedBox(height: 90, child: Padding(padding: const EdgeInsets.all(12), child: Image.file(file, fit: BoxFit.contain))),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: () async {
                final png = await Navigator.of(sheet).push<Uint8List>(
                  MaterialPageRoute(fullscreenDialog: true, builder: (_) => const SignaturePadScreen()),
                );
                if (png == null) return;
                await store.add(png);
                if (sheet.mounted) Navigator.pop(sheet, png);
              },
              icon: const Icon(Icons.draw_rounded),
              label: const Text('Draw a new signature'),
            ),
          ],
        ),
      );
    });
  }

  void _cancelPlacing() {
    _placing.value?.image.dispose();
    _placing.value = null;
    setState(() {});
  }

  void _movePlacing(int delta) {
    final placing = _placing.value;
    final count = _document?.pages.length ?? 1;
    if (placing == null) return;
    final page = (placing.page + delta).clamp(1, count);
    _placing.value = placing.copyWith(page: page);
    _controller.goToPage(pageNumber: page);
  }

  /// Writes the placed signature into the file, keeping a backup of the
  /// previous version, and reopens it.
  Future<void> _applySignature() async {
    final placing = _placing.value;
    if (placing == null || _stamping) return;
    final library = AppScope.of(context).library;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _stamping = true);
    try {
      final bytes = await stampSignatures(
        await File(_file.path).readAsBytes(),
        [SignaturePlacement(pageNumber: placing.page, rect: placing.rect, rgba: placing.rgba, width: placing.image.width, height: placing.image.height)],
        password: _password,
      );
      final updated = await library.saveEdited(_file, bytes);
      if (!mounted) return;
      placing.image.dispose();
      _placing.value = null;
      _searcher?.removeListener(_onSearchChanged);
      _searcher?.dispose();
      setState(() {
        _file = updated;
        _searcher = null;
        _document = null;
        _passwordReused = false;
        _revision++;
      });
      messenger.showSnackBar(const SnackBar(content: Text('Signed and saved. The unsigned version is kept as a backup.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not sign this PDF: $e')));
    } finally {
      if (mounted) setState(() => _stamping = false);
    }
  }

  List<Widget> _pageOverlays(BuildContext context, Rect pageRect, PdfPage page) => [
        Positioned.fill(
          child: ValueListenableBuilder(
            valueListenable: _placing,
            builder: (context, placing, _) {
              if (placing == null || placing.page != page.pageNumber) return const SizedBox.shrink();
              return Stack(children: [
                _SignatureBox(placement: placing, pageSize: pageRect.size, notifier: _placing),
              ]);
            },
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final p = context.palette;
    final pages = _document?.pages.length;
    final placing = _placing.value != null;
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
                _file.path,
                key: ValueKey(_revision),
                controller: _controller,
                passwordProvider: _providePassword,
                initialPageNumber: _page,
                params: PdfViewerParams(
                  // While a signature is being placed, drags move it, not the page.
                  panEnabled: !placing,
                  scaleEnabled: !placing,
                  pageOverlaysBuilder: _pageOverlays,
                  backgroundColor: p.background,
                  margin: 14,
                  boundaryMargin: const EdgeInsets.only(top: 120, bottom: 140),
                  pageDropShadow: BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 30, offset: const Offset(0, 14)),
                  pagePaintCallbacks: [(canvas, rect, page) => _searcher?.pageTextMatchPaintCallback(canvas, rect, page)],
                  onViewerReady: (document, controller) => setState(() {
                    _document = document;
                    _searcher ??= PdfTextSearcher(_controller)..addListener(_onSearchChanged);
                  }),
                  onPageChanged: (page) {
                    if (page != null) setState(() => _page = page);
                  },
                  onGeneralTap: (context, controller, details) {
                    if (placing) return false;
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
                  title: _file.name,
                  subtitle: pages == null ? 'Opening…' : 'Page $_page of $pages',
                  actions: [
                    IconButton(tooltip: 'Share', onPressed: () => shareDocument(_file), icon: const Icon(Icons.ios_share_rounded, size: 21)),
                  ],
                ),
                if (_searching && _searcher != null) _SearchBar(controller: _searchField, searcher: _searcher!, onClose: _toggleSearch),
              ],
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            bottom: _chrome ? 0 : -140,
            child: placing
                ? ValueListenableBuilder(
                    valueListenable: _placing,
                    builder: (context, value, _) => _PlacingBar(
                      page: value?.page ?? _page,
                      pages: pages ?? 1,
                      busy: _stamping,
                      onCancel: _cancelPlacing,
                      onMove: _movePlacing,
                      onApply: _applySignature,
                    ),
                  )
                : ReaderDock(actions: [
                    DockAction(Icons.format_list_bulleted_rounded, 'Contents', _showContents),
                    DockAction(Icons.search_rounded, 'Search', _toggleSearch, active: _searching),
                    DockAction(Icons.draw_rounded, 'Sign', _sign),
                    DockAction(Icons.contrast_rounded, 'Page', () => showPageToneSheet(context, settings)),
                    DockAction(Icons.ios_share_rounded, 'Share', () => shareDocument(_file)),
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

class _Placement {
  const _Placement({required this.page, required this.rect, required this.image, required this.rgba});

  final int page;

  /// Fractions of the page, top-left origin.
  final Rect rect;
  final ui.Image image;
  final Uint8List rgba;

  _Placement copyWith({int? page, Rect? rect}) => _Placement(page: page ?? this.page, rect: rect ?? this.rect, image: image, rgba: rgba);
}

/// The signature on its page: drag to move, drag the corner to resize.
class _SignatureBox extends StatelessWidget {
  const _SignatureBox({required this.placement, required this.pageSize, required this.notifier});

  final _Placement placement;
  final Size pageSize;

  /// Several drags can arrive before a rebuild, so each one starts from the
  /// notifier's current value rather than [placement].
  final ValueNotifier<_Placement?> notifier;

  void onChanged(Rect rect) => notifier.value = notifier.value?.copyWith(rect: rect);

  static const _handle = 30.0;

  void _move(Offset delta) {
    final r = notifier.value!.rect;
    final left = (r.left + delta.dx / pageSize.width).clamp(0.0, 1 - r.width);
    final top = (r.top + delta.dy / pageSize.height).clamp(0.0, 1 - r.height);
    onChanged(Rect.fromLTWH(left, top, r.width, r.height));
  }

  void _resize(Offset delta) {
    final r = notifier.value!.rect;
    final ratio = r.height / r.width;
    // Keep the drawing's shape, at least a handle wide, and on the page.
    final min = _handle * 1.6 / pageSize.width;
    final max = [1 - r.left, (1 - r.top) / ratio].reduce((a, b) => a < b ? a : b);
    final width = (r.width + delta.dx / pageSize.width).clamp(min, max < min ? min : max);
    onChanged(Rect.fromLTWH(r.left, r.top, width, width * ratio));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final r = placement.rect;
    return Positioned(
      left: r.left * pageSize.width,
      top: r.top * pageSize.height,
      width: r.width * pageSize.width,
      height: r.height * pageSize.height,
      child: GestureDetector(
        key: const Key('signature-box'),
        dragStartBehavior: DragStartBehavior.down,
        onPanUpdate: (d) => _move(d.delta),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: 0.08),
            border: Border.all(color: p.accent, width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RawImage(image: placement.image, fit: BoxFit.fill),
              Positioned(
                right: 0,
                bottom: 0,
                width: _handle,
                height: _handle,
                child: GestureDetector(
                  key: const Key('signature-resize'),
                  dragStartBehavior: DragStartBehavior.down,
                  onPanUpdate: (d) => _resize(d.delta),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: p.accent, borderRadius: const BorderRadius.only(topLeft: Radius.circular(10))),
                    child: const Icon(Icons.open_in_full_rounded, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlacingBar extends StatelessWidget {
  const _PlacingBar({required this.page, required this.pages, required this.busy, required this.onCancel, required this.onMove, required this.onApply});

  final int page;
  final int pages;
  final bool busy;
  final VoidCallback onCancel;
  final ValueChanged<int> onMove;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: GlassPanel(
          strong: true,
          radius: 26,
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Drag the signature into place. Drag its corner to resize.', style: TextStyle(color: p.textMuted, fontSize: 13)),
                  ),
                  IconButton(
                    tooltip: 'Previous page',
                    visualDensity: VisualDensity.compact,
                    onPressed: busy || page <= 1 ? null : () => onMove(-1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Text('$page / $pages', style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    tooltip: 'Next page',
                    visualDensity: VisualDensity.compact,
                    onPressed: busy || page >= pages ? null : () => onMove(1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: busy ? null : onCancel, child: const Text('Cancel'))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const Key('apply-signature'),
                      onPressed: busy ? null : onApply,
                      child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Sign here'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
