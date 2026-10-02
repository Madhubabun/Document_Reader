import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../services/ooxml/docx_editor.dart';
import '../../services/ooxml/docx_reader.dart';
import '../../services/settings_store.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/pinch_zoom.dart';
import '../../widgets/reader_chrome.dart';

/// Office fonts first; Carlito and Liberation are metric-compatible stand-ins
/// where Calibri/Arial/Times are not installed.
/// Calibri-compatible Latin first, then bundled Indian-language scripts so
/// Telugu, Hindi, Tamil, Kannada, Malayalam and Bengali text renders the same
/// on every phone (fonts like Gautami or Nirmala UI only exist on Windows).
const officeFontFallback = [
  'Calibri',
  'Carlito',
  'NotoSansTelugu',
  'NotoSansDevanagari',
  'NotoSansTamil',
  'NotoSansKannada',
  'NotoSansMalayalam',
  'NotoSansBengali',
  'Arial',
  'Liberation Sans',
  'Helvetica',
];

/// Marks the start of the paragraph being edited, so Backspace at the start
/// (which deletes it) can join the paragraph onto the one before.
const _start = '​';

/// Reflowed Word document on a paper-like page.
///
/// With an [editor] and [editing] on, tapping a paragraph puts the cursor
/// there. Typing changes only that text; Enter starts a new paragraph and
/// Backspace at the start joins paragraphs. The toolbar formats the
/// selected text, or the whole paragraph when nothing is selected.
class WordView extends StatefulWidget {
  const WordView({
    super.key,
    required this.document,
    required this.tone,
    required this.outlineRequests,
    required this.onStatus,
    this.editor,
    this.editing = false,
    this.onChanged,
    this.onDoneEditing,
  });

  final DocxDocument document;
  final PageTone tone;
  final ValueListenable<int> outlineRequests;
  final ValueChanged<String> onStatus;
  final DocxEditor? editor;
  final bool editing;
  final VoidCallback? onChanged;
  final VoidCallback? onDoneEditing;

  @override
  State<WordView> createState() => _WordViewState();
}

class _WordViewState extends State<WordView> {
  List<GlobalKey> _keys = [];
  final _scroll = ScrollController();
  final _focus = FocusNode();
  late final _RunsController _controller = _RunsController(() => _activeParagraph);
  final _textKeys = <int, GlobalKey>{};

  /// The paragraph being edited, and whether it has changed since the cursor
  /// went there (the first change starts an undo step).
  int? _active;
  bool _typed = false;
  String _lastText = '';

  DocxDocument get _document => widget.editor?.document ?? widget.document;
  bool get _editing => widget.editing && widget.editor != null;

  DocxParagraph? get _activeParagraph {
    final ref = _active;
    if (ref == null) return null;
    for (final b in _document.blocks) {
      if (b is DocxParagraph && b.ref == ref) return b;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.outlineRequests.addListener(_showOutline);
    _controller.addListener(_onTextChanged);
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(WordView old) {
    super.didUpdateWidget(old);
    if (!widget.editing && old.editing) _deactivate();
  }

  @override
  void dispose() {
    widget.outlineRequests.removeListener(_showOutline);
    _scroll.dispose();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _showOutline() async {
    final blocks = _document.blocks;
    final headings = <(int, DocxParagraph)>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b is DocxParagraph && (b.headingLevel > 0 || b.isTitle) && b.text.trim().isNotEmpty) headings.add((i, b));
    }
    final index = await showGlassSheet<int>(context, (sheet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Outline', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 10),
          if (headings.isEmpty) Text('This document has no headings.', style: TextStyle(color: sheet.palette.textMuted)),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.55),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (i, h) in headings)
                  ListTile(
                    contentPadding: EdgeInsets.only(left: 14.0 * (h.headingLevel > 0 ? h.headingLevel - 1 : 0)),
                    title: Text(h.text.trim(), style: TextStyle(fontWeight: h.headingLevel <= 1 ? FontWeight.w700 : FontWeight.w500)),
                    onTap: () => Navigator.pop(sheet, i),
                  ),
              ],
            ),
          ),
        ],
      );
    });
    final ctx = index == null || index >= _keys.length ? null : _keys[index].currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.15);
    }
  }

  // ---------------------------------------------------------------------------
  // Editing

  /// Puts the cursor in paragraph [ref] at [offset] (end when null).
  void _activate(int ref, [int? offset]) {
    final paragraph = _document.blocks.whereType<DocxParagraph>().where((p) => p.ref == ref).firstOrNull;
    if (paragraph == null) return;
    final text = paragraph.text;
    setState(() {
      _active = ref;
      _typed = false;
      _lastText = text;
    });
    _controller.value = TextEditingValue(
      text: '$_start$text',
      selection: TextSelection.collapsed(offset: 1 + (offset ?? text.length).clamp(0, text.length)),
    );
    _focus.requestFocus();
  }

  void _deactivate() {
    _focus.unfocus();
    setState(() => _active = null);
  }

  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  void _onTextChanged() {
    final ref = _active;
    final editor = widget.editor;
    if (ref == null || editor == null) return;
    final raw = _controller.text;
    final selection = _controller.selection;
    if (!raw.contains(_start)) {
      // Backspace at the very start.
      final cursor = editor.joinWithPrevious(ref);
      if (cursor == null) {
        _controller.value = TextEditingValue(text: '$_start$raw', selection: const TextSelection.collapsed(offset: 1));
        return;
      }
      _changed();
      _activate(ref - 1, cursor);
      return;
    }
    if (!raw.startsWith(_start) || (selection.isValid && selection.start == 0)) {
      // Keep the marker first and the cursor after it.
      final text = raw.replaceAll(_start, '');
      final cursor = selection.isValid ? (selection.extentOffset - (raw.indexOf(_start) < selection.extentOffset ? 1 : 0)).clamp(0, text.length) : text.length;
      _controller.value = TextEditingValue(text: '$_start$text', selection: TextSelection.collapsed(offset: cursor + 1));
      return;
    }
    final text = raw.substring(1);
    if (text == _lastText) return;
    // A single new line typed (Enter) starts a new paragraph; pasted lines
    // stay as line breaks inside the paragraph.
    final before = '\n'.allMatches(_lastText).length;
    final after = '\n'.allMatches(text).length;
    if (after == before + 1 && text.length == _lastText.length + 1) {
      var at = 0;
      while (at < _lastText.length && _lastText.codeUnitAt(at) == text.codeUnitAt(at)) {
        at++;
      }
      if (text[at] == '\n') {
        final next = editor.splitParagraph(ref, at);
        _changed();
        _activate(next, 0);
        return;
      }
    }
    if (!_typed) {
      editor.checkpoint();
      _typed = true;
    }
    editor.setParagraphText(ref, text);
    _lastText = text;
    _changed();
  }

  /// The selected characters of the active paragraph (without the marker).
  (int, int) get _range {
    final s = _controller.selection;
    if (!s.isValid) return (0, 0);
    return ((s.start - 1).clamp(0, _lastText.length), (s.end - 1).clamp(0, _lastText.length));
  }

  DocxRun? get _runAtCursor {
    final p = _activeParagraph;
    if (p == null || p.runs.isEmpty) return null;
    final (start, end) = _range;
    var pos = 0;
    for (final r in p.runs) {
      // The character after the cursor for a selection, before it otherwise.
      if ((start < end && start < pos + r.text.length) || (start == end && start <= pos + r.text.length)) return r;
      pos += r.text.length;
    }
    return p.runs.last;
  }

  void _format(void Function(DocxEditor editor, int ref, int start, int end) change) {
    final ref = _active;
    final editor = widget.editor;
    if (ref == null || editor == null) return;
    final (start, end) = _range;
    change(editor, ref, start, end);
    _typed = false;
    _changed();
  }

  void _undo() {
    final editor = widget.editor;
    if (editor == null || !editor.undo()) return;
    _deactivate();
    widget.onChanged?.call();
  }

  Future<void> _pickColor({required bool highlight}) async {
    const textColors = ['000000', '404040', '808080', 'C00000', 'FF0000', 'FFC000', '00B050', '0070C0', '002060', '7030A0'];
    const highlights = {
      'yellow': Color(0xFFFFFF00),
      'green': Color(0xFF00FF00),
      'cyan': Color(0xFF00FFFF),
      'magenta': Color(0xFFFF00FF),
      'blue': Color(0xFF0000FF),
      'red': Color(0xFFFF0000),
      'lightGray': Color(0xFFC0C0C0),
    };
    final picked = await showGlassSheet<String>(
      context,
      (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(highlight ? 'Highlight' : 'Text colour', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _Swatch(null, highlight ? 'None' : 'Automatic', () => Navigator.pop(sheet, '')),
            if (highlight)
              for (final e in highlights.entries) _Swatch(e.value, e.key, () => Navigator.pop(sheet, e.key))
            else
              for (final rgb in textColors) _Swatch(Color(int.parse('FF$rgb', radix: 16)), rgb, () => Navigator.pop(sheet, rgb)),
          ]),
        ],
      ),
    );
    if (picked == null) return;
    final value = picked.isEmpty ? null : picked;
    _format((e, ref, s, t) => highlight ? e.setHighlight(ref, s, t, value) : e.setColor(ref, s, t, value));
    _focus.requestFocus();
  }

  Future<void> _textStyleSheet() async {
    final p = _activeParagraph;
    if (p == null) return;
    final run = _runAtCursor;
    final size = run?.fontSizePt ?? 11;
    final current = p.isTitle
        ? DocxParagraphKind.title
        : switch (p.headingLevel) { 1 => DocxParagraphKind.heading1, 2 => DocxParagraphKind.heading2, 3 => DocxParagraphKind.heading3, _ => DocxParagraphKind.normal };
    await showGlassSheet<void>(
      context,
      (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Text', style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (kind, label) in const [
                (DocxParagraphKind.normal, 'Normal'),
                (DocxParagraphKind.title, 'Title'),
                (DocxParagraphKind.heading1, 'Heading 1'),
                (DocxParagraphKind.heading2, 'Heading 2'),
                (DocxParagraphKind.heading3, 'Heading 3'),
              ])
                GlassChip(
                  label: label,
                  selected: kind == current,
                  onTap: () {
                    widget.editor!.setParagraphKind(_active!, kind);
                    _changed();
                    Navigator.pop(sheet);
                  },
                ),
            ]),
            const SizedBox(height: 16),
            Text('Font', style: TextStyle(color: sheet.palette.textMuted, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final font in const ['Calibri', 'Arial', 'Times New Roman', 'Cambria', 'Georgia', 'Verdana'])
                GlassChip(
                  label: font,
                  selected: (run?.font ?? '') == font,
                  onTap: () {
                    _format((e, ref, s, t) => e.setFont(ref, s, t, font));
                    Navigator.pop(sheet);
                  },
                ),
            ]),
            const SizedBox(height: 16),
            Text('Size', style: TextStyle(color: sheet.palette.textMuted, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final pt in const [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36])
                GlassChip(
                  label: '$pt',
                  selected: size == pt,
                  onTap: () {
                    _format((e, ref, s, t) => e.setFontSize(ref, s, t, pt.toDouble()));
                    Navigator.pop(sheet);
                  },
                ),
            ]),
          ],
        ),
      ),
    );
    _focus.requestFocus();
  }

  Future<void> _editCell(DocxTable table, int row, int col) async {
    final editor = widget.editor;
    final ref = table.ref;
    if (editor == null || ref == null) return;
    _deactivate();
    final controller = TextEditingController(text: col < table.rows[row].length ? table.rows[row][col] : '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit cell'),
        content: TextField(controller: controller, autofocus: true, maxLines: null, minLines: 2),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('OK')),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    editor.setCellText(ref, row, col, result);
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Building

  @override
  Widget build(BuildContext context) {
    final document = _document;
    if (_keys.length != document.blocks.length) _keys = List.generate(document.blocks.length, (_) => GlobalKey());
    final words = document.plainText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    widget.onStatus(_editing ? 'Editing · $words words' : '$words words · ${(words / 230).ceil()} min read');
    final filter = pageToneFilter(widget.tone);
    final page = Container(
      constraints: const BoxConstraints(maxWidth: 720),
      padding: const EdgeInsets.fromLTRB(26, 30, 26, 36),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFBFA),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 40, offset: const Offset(0, 18))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < document.blocks.length; i++) KeyedSubtree(key: _keys[i], child: _block(document.blocks[i])),
          if (document.blocks.isEmpty) const Text('This document is empty.', style: TextStyle(color: Color(0xFF6B7280))),
        ],
      ),
    );
    final view = PinchZoom(
      maxZoom: 2.5,
      vertical: _scroll,
      builder: (context, pinching) => SingleChildScrollView(
        controller: _scroll,
        physics: pinching ? const NeverScrollableScrollPhysics() : null,
        padding: EdgeInsets.fromLTRB(14, 8, 14, _editing ? 40 : 140),
        // Night and sepia tones are for reading; edit on plain paper.
        child: Center(child: filter == null || _editing ? page : ColorFiltered(colorFilter: filter, child: page)),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 84),
      child: _editing ? Column(children: [Expanded(child: view), _toolbar()]) : view,
    );
  }

  Widget _toolbar() {
    final editor = widget.editor!;
    final active = _active != null && _focus.hasFocus;
    final run = active ? _runAtCursor : null;
    final paragraph = active ? _activeParagraph : null;
    Widget button(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GlassIconButton(icon: icon, tooltip: tip, onPressed: onTap, size: 40, color: on ? FileColors.word : null),
        );
    VoidCallback? when(bool enabled, VoidCallback action) => enabled ? action : null;
    final align = paragraph?.align ?? ParagraphAlign.left;
    final nextAlign = switch (align) {
      ParagraphAlign.left => ParagraphAlign.center,
      ParagraphAlign.center => ParagraphAlign.right,
      ParagraphAlign.right => ParagraphAlign.justify,
      ParagraphAlign.justify => ParagraphAlign.left,
    };
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  button(Icons.undo_rounded, 'Undo', when(editor.canUndo, _undo)),
                  button(Icons.format_bold_rounded, 'Bold', when(active, () => _format((e, r, s, t) => e.setBold(r, s, t, !(run?.bold ?? false)))), on: run?.bold ?? false),
                  button(Icons.format_italic_rounded, 'Italic', when(active, () => _format((e, r, s, t) => e.setItalic(r, s, t, !(run?.italic ?? false)))), on: run?.italic ?? false),
                  button(Icons.format_underlined_rounded, 'Underline', when(active, () => _format((e, r, s, t) => e.setUnderline(r, s, t, !(run?.underline ?? false)))),
                      on: run?.underline ?? false),
                  button(Icons.text_fields_rounded, 'Style, font and size', when(active, _textStyleSheet)),
                  button(Icons.format_color_text_rounded, 'Text colour', when(active, () => _pickColor(highlight: false))),
                  button(Icons.border_color_rounded, 'Highlight', when(active, () => _pickColor(highlight: true))),
                  button(
                    switch (align) {
                      ParagraphAlign.center => Icons.format_align_center_rounded,
                      ParagraphAlign.right => Icons.format_align_right_rounded,
                      ParagraphAlign.justify => Icons.format_align_justify_rounded,
                      ParagraphAlign.left => Icons.format_align_left_rounded,
                    },
                    'Alignment',
                    when(active, () => _format((e, r, s, t) => e.setAlignment(r, nextAlign))),
                  ),
                  button(Icons.format_list_bulleted_rounded, 'Bullets', when(active, () => _format((e, r, s, t) => e.toggleBullets(r))), on: paragraph?.listLevel != null),
                ],
              ),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: () {
                _deactivate();
                widget.onDoneEditing?.call();
              },
              style: FilledButton.styleFrom(backgroundColor: FileColors.word, foregroundColor: Colors.white),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _block(DocxBlock block) => switch (block) {
        DocxParagraph p => _paragraph(p),
        DocxTable t => _table(t),
        DocxPageBreak _ => const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(color: Color(0xFFD9D9E0), thickness: 1),
          ),
        DocxImage img => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Image.memory(img.bytes, fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ),
      };

  /// 11pt Word body text reads well at about 15 logical pixels on a phone.
  static const _ptToPx = 15 / 11;

  static TextStyle _baseStyle(DocxParagraph p) {
    final baseSize = p.isTitle
        ? 28.0
        : switch (p.headingLevel) {
            1 => 23.0,
            2 => 19.5,
            3 => 17.0,
            4 || 5 || 6 => 15.5,
            _ => 15.0,
          };
    final isHeading = p.isTitle || p.headingLevel > 0;
    return TextStyle(
      fontFamily: 'Calibri',
      fontFamilyFallback: officeFontFallback,
      fontSize: baseSize,
      height: isHeading ? 1.25 : 1.55,
      fontWeight: isHeading ? FontWeight.w700 : FontWeight.w400,
      color: isHeading && !p.isTitle ? const Color(0xFF1F3B73) : const Color(0xFF1C1C22),
    );
  }

  static TextStyle _runStyle(DocxParagraph p, DocxRun r) {
    final isHeading = p.isTitle || p.headingLevel > 0;
    return TextStyle(
      fontFamily: r.font == null ? null : _flutterFont(r.font!),
      fontWeight: r.bold ? FontWeight.w700 : null,
      fontStyle: r.italic ? FontStyle.italic : null,
      decoration: TextDecoration.combine([
        if (r.underline) TextDecoration.underline,
        if (r.strike) TextDecoration.lineThrough,
      ]),
      fontSize: (!isHeading && r.fontSizePt != null) ? (r.fontSizePt! * _ptToPx).clamp(9.0, 48.0) : null,
      color: _hex(r.color),
      backgroundColor: _highlight(r.highlight),
    );
  }

  /// Office fonts mapped to the bundled look-alikes; others fall back.
  static String? _flutterFont(String font) => switch (font.toLowerCase()) {
        'calibri' || 'calibri light' => 'Calibri',
        'times new roman' || 'cambria' || 'georgia' => 'serif',
        'courier new' || 'consolas' => 'monospace',
        _ => null,
      };

  static List<InlineSpan> _spans(DocxParagraph p) => [for (final r in p.runs) TextSpan(text: r.text, style: _runStyle(p, r))];

  Widget _paragraph(DocxParagraph p) {
    final base = _baseStyle(p);
    final isHeading = p.isTitle || p.headingLevel > 0;
    final align = switch (p.align) {
      ParagraphAlign.center => TextAlign.center,
      ParagraphAlign.right => TextAlign.right,
      ParagraphAlign.justify => TextAlign.justify,
      ParagraphAlign.left => TextAlign.left,
    };
    final ref = p.ref;
    final editingThis = _editing && ref != null && ref == _active;
    Widget text;
    if (editingThis) {
      text = TextField(
        key: const ValueKey('word-editor'),
        controller: _controller,
        focusNode: _focus,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textAlign: align,
        style: base,
        cursorColor: FileColors.word,
        decoration: const InputDecoration.collapsed(hintText: ''),
      );
    } else if (p.runs.isEmpty) {
      text = SizedBox(height: _editing ? base.fontSize! * base.height! : 10);
    } else {
      final key = ref == null ? null : _textKeys.putIfAbsent(ref, GlobalKey.new);
      text = Text.rich(key: key, TextSpan(style: base, children: _spans(p)), textAlign: align);
    }
    if (_editing && ref != null && !editingThis) {
      text = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          int? offset;
          final box = _textKeys[ref]?.currentContext?.findRenderObject();
          if (box is RenderParagraph) offset = box.getPositionForOffset(box.globalToLocal(details.globalPosition)).offset;
          _activate(ref, offset);
        },
        child: text,
      );
    }
    final padding = EdgeInsets.only(top: isHeading ? 14 : 0, bottom: isHeading ? 6 : 8);
    if (p.listLevel == null) return Padding(padding: padding, child: text);
    return Padding(
      padding: padding.add(EdgeInsets.only(left: 18.0 * p.listLevel!)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 18, child: Text('•', style: base)),
          Expanded(child: text),
        ],
      ),
    );
  }

  Widget _table(DocxTable t) {
    if (t.rows.isEmpty) return const SizedBox.shrink();
    final cols = t.rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    const style = TextStyle(fontFamily: 'Calibri', fontFamilyFallback: officeFontFallback, fontSize: 13, color: Color(0xFF1C1C22), height: 1.35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: MediaQuery.sizeOf(context).width - 80),
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: const Color(0xFFD9D9E0), borderRadius: BorderRadius.circular(4)),
            children: [
              for (var r = 0; r < t.rows.length; r++)
                TableRow(
                  decoration: r == 0 ? const BoxDecoration(color: Color(0xFFEEF3FF)) : null,
                  children: [
                    for (var c = 0; c < cols; c++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _editing && c < t.rows[r].length ? () => _editCell(t, r, c) : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220, minWidth: 24),
                            child: Text(c < t.rows[r].length ? t.rows[r][c] : '', style: r == 0 ? style.copyWith(fontWeight: FontWeight.w700) : style),
                          ),
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

  static Color? _hex(String? hex) {
    if (hex == null || hex.length != 6) return null;
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  static Color? _highlight(String? name) => switch (name) {
        'yellow' => const Color(0xFFFFF176),
        'green' => const Color(0xFFA5F3A1),
        'cyan' => const Color(0xFFA5F3FC),
        'magenta' => const Color(0xFFF5A3F0),
        'blue' => const Color(0xFF93C5FD),
        'red' => const Color(0xFFFCA5A5),
        'lightGray' => const Color(0xFFE5E7EB),
        _ => null,
      };
}

/// Shows the paragraph being edited with its runs' formatting. The editor
/// is updated on every change, so the runs always match the text.
class _RunsController extends TextEditingController {
  _RunsController(this._paragraph);

  final DocxParagraph? Function() _paragraph;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final p = _paragraph();
    final value = text;
    if (p == null || !value.startsWith(_start) || p.text != value.substring(1)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final composing = withComposing && this.value.isComposingRangeValid ? this.value.composing : TextRange.empty;
    final children = <InlineSpan>[const TextSpan(text: _start)];
    var pos = 1;
    for (final r in p.runs) {
      final runStyle = _WordViewState._runStyle(p, r);
      final start = pos;
      final end = pos + r.text.length;
      pos = end;
      if (composing.isValid && composing.start < end && composing.end > start) {
        // Underline the word being composed by the keyboard, like Flutter does.
        final a = composing.start.clamp(start, end);
        final b = composing.end.clamp(start, end);
        children
          ..add(TextSpan(text: value.substring(start, a), style: runStyle))
          ..add(TextSpan(text: value.substring(a, b), style: runStyle.merge(const TextStyle(decoration: TextDecoration.underline))))
          ..add(TextSpan(text: value.substring(b, end), style: runStyle));
      } else {
        children.add(TextSpan(text: value.substring(start, end), style: runStyle));
      }
    }
    return TextSpan(style: style, children: children);
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color, this.label, this.onTap);

  final Color? color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: color ?? Colors.white, shape: BoxShape.circle, border: Border.all(color: context.palette.glassBorder, width: 1.5)),
          child: color == null ? const Icon(Icons.format_color_reset_rounded, size: 20, color: Color(0xFF6B7280)) : null,
        ),
      ),
    );
  }
}
