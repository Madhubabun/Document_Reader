import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../services/pdf_edits.dart';
import '../services/signature_store.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/reader_chrome.dart';
import 'pdf/pdf_form.dart';
import 'pdf/pdf_markup.dart';
import 'pdf/pdf_tool_flows.dart';
import 'signature_pad_screen.dart';

enum _Mode { view, sign, markup, form }

/// Immersive PDF reader: tap the page to show or hide the floating glass bars.
class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key, required this.file, this.password});

  final DocFile file;

  /// The password, when the file was just unlocked by a tool.
  final String? password;

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
  late String? _password = widget.password;
  bool _passwordReused = false;

  _Mode _mode = _Mode.view;

  /// The signature being placed, if any.
  final _placing = ValueNotifier<_Placement?>(null);

  /// Annotations or form values not yet saved.
  MarkupController? _markup;
  MarkupTool? _markupTool;
  FormController? _form;

  /// Saving, or reading the form.
  bool _busy = false;

  @override
  void dispose() {
    _searcher?.removeListener(_onSearchChanged);
    _searcher?.dispose();
    _searchField.dispose();
    _placing.value?.image.dispose();
    _placing.dispose();
    _markup?.dispose();
    _form?.dispose();
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
    if (doc == null || _busy) return;
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
    _enter(_Mode.sign);
  }

  void _enter(_Mode mode) {
    setState(() {
      _mode = mode;
      _chrome = true;
      if (_searching) _toggleSearch();
    });
  }

  void _startMarkup() {
    if (_document == null || _busy) return;
    _markup?.dispose();
    _markup = MarkupController()..addListener(_onMarkupChanged);
    _markupTool = _markup!.tool;
    _enter(_Mode.markup);
  }

  /// Drawing tools lock the page in place so drags draw; Scroll frees it.
  void _onMarkupChanged() {
    final tool = _markup?.tool;
    if (tool != _markupTool && mounted) setState(() => _markupTool = tool);
  }

  Future<void> _startForm() async {
    if (_document == null || _busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final fields = await readFormFields(await File(_file.path).readAsBytes(), password: _password);
      if (!mounted) return;
      if (fields.isEmpty) {
        messenger.showSnackBar(_snack('This PDF has no fillable fields.'));
        return;
      }
      _form?.dispose();
      _form = FormController(fields);
      _enter(_Mode.form);
    } catch (e) {
      messenger.showSnackBar(_snack('Could not read the form: ${_reason(e)}'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _reason(Object e) => e is StateError ? e.message : '$e';

  bool get _hasUnsaved => switch (_mode) {
        _Mode.view => false,
        _Mode.sign => true,
        _Mode.markup => _markup?.edits.isNotEmpty ?? false,
        _Mode.form => _form?.hasChanges ?? false,
      };

  /// Leaves the current tool, asking first when there is unsaved work.
  Future<void> _cancelMode() async {
    if (_busy) return;
    if (_hasUnsaved && _mode != _Mode.sign) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard your changes?'),
          content: const Text('They have not been saved to the file.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    _leaveMode();
  }

  void _leaveMode() {
    _placing.value?.image.dispose();
    _placing.value = null;
    // The bars and page layers still listen to these until the next frame.
    final markup = _markup;
    final form = _form;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      markup?.dispose();
      form?.dispose();
    });
    _markup = null;
    _markupTool = null;
    _form = null;
    setState(() => _mode = _Mode.view);
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

  void _movePlacing(int delta) {
    final placing = _placing.value;
    final count = _document?.pages.length ?? 1;
    if (placing == null) return;
    final page = (placing.page + delta).clamp(1, count);
    _placing.value = placing.copyWith(page: page);
    _controller.goToPage(pageNumber: page);
  }

  Future<void> _applySignature() async {
    final placing = _placing.value;
    if (placing == null) return;
    await _save(
      [ImageEdit(placing.page, rect: placing.rect, rgba: placing.rgba, width: placing.image.width, height: placing.image.height)],
      done: 'Signed and saved. The unsigned version is kept as a backup.',
      failed: 'Could not sign this PDF',
    );
  }

  /// Writes [edits] into the file, keeping a backup of the previous version,
  /// and reopens it.
  Future<void> _save(List<PdfEdit> edits, {required String done, required String failed}) async {
    if (_busy || edits.isEmpty) return;
    final library = AppScope.of(context).library;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await applyPdfEdits(await File(_file.path).readAsBytes(), edits, password: _password);
      final updated = await library.saveEdited(_file, bytes);
      if (!mounted) return;
      _leaveMode();
      _searcher?.removeListener(_onSearchChanged);
      _searcher?.dispose();
      setState(() {
        _file = updated;
        _searcher = null;
        _document = null;
        _passwordReused = false;
        _revision++;
      });
      messenger.showSnackBar(_snack(done));
    } catch (e) {
      messenger.showSnackBar(_snack('$failed: ${_reason(e)}'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reopens the viewer on a file a tool replaced.
  void _reloadWith(ToolChange? change) {
    if (change == null || !mounted) return;
    _searcher?.removeListener(_onSearchChanged);
    _searcher?.dispose();
    setState(() {
      _file = change.file;
      _password = change.password;
      _passwordReused = false;
      _searcher = null;
      _searching = false;
      _document = null;
      _page = 1;
      _revision++;
    });
  }

  Future<void> _showTools() async {
    final locked = _password != null;
    final picked = await showGlassSheet<Future<void> Function()>(context, (sheet) {
      Widget row(String label, IconData icon, Key key, Future<void> Function() action) => ListTile(
            key: key,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(icon),
            title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(sheet, action),
          );
      return Flexible(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('PDF tools', style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: 6),
              row('Organize pages', Icons.view_agenda_outlined, const Key('menu-organize'), () async => _reloadWith(await organizeFile(context, _file, password: _password))),
              row('Split into files', Icons.call_split_rounded, const Key('menu-split'), () => splitFile(context, _file, password: _password)),
              row('Make a smaller copy', Icons.compress_rounded, const Key('menu-compress'), () => compressFile(context, _file, password: _password)),
              row('Make scanned text searchable', Icons.manage_search_rounded, const Key('menu-searchable'),
                  () async => _reloadWith(await makeSearchable(context, _file, password: _password))),
              row(locked ? 'Change the password' : 'Add a password', Icons.lock_outline_rounded, const Key('menu-lock'),
                  () async => _reloadWith(await lockFile(context, _file, password: _password))),
              if (locked)
                row('Remove the password', Icons.lock_open_rounded, const Key('menu-unlock'), () async => _reloadWith(await unlockFile(context, _file, password: _password))),
            ],
          ),
        ),
      );
    });
    if (picked != null && mounted) await picked();
  }

  List<Widget> _pageOverlays(BuildContext context, Rect pageRect, PdfPage page) => switch (_mode) {
        _Mode.view => const [],
        _Mode.markup => [
            Positioned.fill(
              child: MarkupLayer(
                page: page,
                pageSize: pageRect.size,
                controller: _markup!,
                onNoText: () => _hint('Drag across text to mark it up. This page may be a scan with no text; use the pen instead.'),
              ),
            ),
          ],
        _Mode.form => [
            Positioned.fill(
              child: FormLayer(
                pageNumber: page.pageNumber,
                pageSize: pageRect.size,
                controller: _form!,
                onLocked: () => _hint('This field is locked by the form and cannot be changed.'),
              ),
            ),
          ],
        _Mode.sign => [_signatureOverlay(page, pageRect)],
      };

  void _hint(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(_snack(message, duration: const Duration(seconds: 3)));
  }

  /// A message that floats above the bottom bar instead of covering it.
  SnackBar _snack(String message, {Duration duration = const Duration(seconds: 4)}) {
    final bar = _mode == _Mode.view ? 100.0 : 210.0;
    return SnackBar(
      content: Text(message),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(16, 0, 16, bar + MediaQuery.paddingOf(context).bottom),
    );
  }

  Widget _signatureOverlay(PdfPage page, Rect pageRect) => Positioned.fill(
          child: ValueListenableBuilder(
            valueListenable: _placing,
            builder: (context, placing, _) {
              if (placing == null || placing.page != page.pageNumber) return const SizedBox.shrink();
              return Stack(children: [
                _SignatureBox(placement: placing, pageSize: pageRect.size, notifier: _placing),
              ]);
            },
          ),
        );

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final p = context.palette;
    final pages = _document?.pages.length;
    final editing = _mode != _Mode.view;
    // Drags draw or move the signature instead of scrolling the page.
    final locked = _mode == _Mode.sign || (_mode == _Mode.markup && _markupTool != MarkupTool.scroll);
    final chrome = _chrome || editing;
    return PopScope(
      canPop: !editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelMode();
      },
      child: Scaffold(
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
                    panEnabled: !locked,
                    scaleEnabled: !locked,
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
                      if (editing) return false;
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
              top: chrome ? 0 : -140,
              child: Column(
                children: [
                  ReaderTopBar(
                    title: _file.name,
                    subtitle: pages == null ? 'Opening…' : 'Page $_page of $pages',
                    actions: [
                      IconButton(tooltip: 'Page colour', onPressed: () => showPageToneSheet(context, settings), icon: const Icon(Icons.contrast_rounded, size: 21)),
                      IconButton(tooltip: 'Share', onPressed: editing ? null : () => shareDocument(_file), icon: const Icon(Icons.ios_share_rounded, size: 21)),
                      IconButton(
                        key: const Key('pdf-tools'),
                        tooltip: 'PDF tools',
                        onPressed: editing || _busy ? null : _showTools,
                        icon: const Icon(Icons.more_vert_rounded, size: 21),
                      ),
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
              bottom: chrome ? 0 : -140,
              child: switch (_mode) {
                _Mode.sign => ValueListenableBuilder(
                    valueListenable: _placing,
                    builder: (context, value, _) => _PlacingBar(
                      page: value?.page ?? _page,
                      pages: pages ?? 1,
                      busy: _busy,
                      onCancel: _cancelMode,
                      onMove: _movePlacing,
                      onApply: _applySignature,
                    ),
                  ),
                _Mode.markup => MarkupBar(
                    controller: _markup!,
                    busy: _busy,
                    onCancel: _cancelMode,
                    onSave: () => _save(List.of(_markup!.edits), done: 'Annotations saved. The previous version is kept as a backup.', failed: 'Could not save the annotations'),
                  ),
                _Mode.form => FormBar(
                    controller: _form!,
                    busy: _busy,
                    onCancel: _cancelMode,
                    onSave: () => _save(_form!.toEdits(), done: 'Form saved. The previous version is kept as a backup.', failed: 'Could not save the form'),
                  ),
                _Mode.view => ReaderDock(actions: [
                    DockAction(Icons.format_list_bulleted_rounded, 'Contents', _showContents),
                    DockAction(Icons.search_rounded, 'Search', _toggleSearch, active: _searching),
                    DockAction(Icons.edit_note_rounded, 'Annotate', _startMarkup),
                    DockAction(Icons.draw_rounded, 'Sign', _sign),
                    DockAction(Icons.assignment_outlined, 'Fill form', _startForm),
                  ]),
              },
            ),
          ],
        ),
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
