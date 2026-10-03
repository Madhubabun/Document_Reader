import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ooxml/ooxml_editor.dart';
import '../../services/ooxml/pptx_geometry.dart';
import '../../services/ooxml/pptx_editor.dart';
import '../../services/ooxml/pptx_reader.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/pinch_zoom.dart';
import '../../widgets/text_dialog.dart';
import 'word_view.dart';

/// Scrollable list of slides; tap one to present full screen.
///
/// With an [editor] and [editing] on, tap a shape to select it, drag it to
/// move it or drag its corner to resize it, and tap it again to change its
/// text. The toolbar formats the selected shape and adds, duplicates,
/// moves and deletes slides.
class SlidesView extends StatefulWidget {
  const SlidesView({
    super.key,
    required this.presentation,
    required this.outlineRequests,
    required this.onStatus,
    this.editor,
    this.editing = false,
    this.onChanged,
    this.onDoneEditing,
  });

  final PptxPresentation presentation;
  final ValueListenable<int> outlineRequests;
  final ValueChanged<String> onStatus;
  final PptxEditor? editor;
  final bool editing;
  final VoidCallback? onChanged;
  final VoidCallback? onDoneEditing;

  @override
  State<SlidesView> createState() => _SlidesViewState();
}

class _SlidesViewState extends State<SlidesView> {
  final _scroll = ScrollController();
  List<GlobalKey> _keys = [];

  /// The slide the toolbar acts on, and the selected shape on it.
  int _slide = 0;
  int? _selected;

  /// While dragging: the shape's rect in EMU, and whether the corner handle
  /// (resize) or the body (move) was grabbed.
  EmuRect? _dragRect;
  EmuRect? _dragStart;
  Offset? _dragOrigin;
  bool _resizing = false;

  PptxPresentation get _presentation => widget.editor?.presentation ?? widget.presentation;
  bool get _editing => widget.editing && widget.editor != null;

  @override
  void initState() {
    super.initState();
    widget.outlineRequests.addListener(_showSlides);
  }

  @override
  void didUpdateWidget(SlidesView old) {
    super.didUpdateWidget(old);
    if (!widget.editing && old.editing) _selected = null;
  }

  @override
  void dispose() {
    widget.outlineRequests.removeListener(_showSlides);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _showSlides() async {
    final slides = _presentation.slides;
    final index = await showGlassSheet<int>(context, (sheet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Slides', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.55),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < slides.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Text('${i + 1}', style: TextStyle(fontWeight: FontWeight.w800, color: FileColors.powerpoint.withValues(alpha: 0.95))),
                    title: Text(slides[i].title ?? 'Slide ${i + 1}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(sheet, i),
                  ),
              ],
            ),
          ),
        ],
      );
    });
    final ctx = index == null || index >= _keys.length ? null : _keys[index].currentContext;
    if (ctx != null && ctx.mounted) await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.2);
  }

  // ---------------------------------------------------------------------------
  // Editing

  void _edit(void Function(PptxEditor editor) change) {
    final editor = widget.editor;
    if (editor == null) return;
    try {
      change(editor);
    } on EditRefused catch (e) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    setState(() {
      _slide = _slide.clamp(0, _presentation.slides.length - 1);
    });
    widget.onChanged?.call();
  }

  PptxShape? get _selectedShape {
    final ref = _selected;
    if (ref == null || _slide >= _presentation.slides.length) return null;
    return _presentation.slides[_slide].shapes.where((s) => s.ref == ref).firstOrNull;
  }

  /// The topmost shape under [emu] on slide [slide], by ref.
  int? _hit(int slide, Offset emu) {
    final s = _presentation.slides[slide];
    final rects = SlideCanvas.rectsFor(_presentation, s);
    for (var i = s.shapes.length - 1; i >= 0; i--) {
      final r = rects[i];
      // Master and layout graphics can't be edited here.
      if (s.shapes[i].ref == null) continue;
      if (emu.dx >= r.x && emu.dx <= r.x + r.width && emu.dy >= r.y && emu.dy <= r.y + r.height) return s.shapes[i].ref;
    }
    return null;
  }

  void _tap(int slide, Offset emu) {
    final ref = _hit(slide, emu);
    if (ref != null && ref == _selected && slide == _slide) {
      final shape = _selectedShape;
      if (shape != null && shape.kind != PptxShapeKind.picture) _editText();
      return;
    }
    setState(() {
      _slide = slide;
      _selected = ref;
    });
  }

  Future<void> _editText() async {
    final shape = _selectedShape;
    final ref = _selected;
    if (shape == null || ref == null || shape.kind == PptxShapeKind.picture) return;
    final result = await showTextDialog(
      context,
      title: 'Edit text',
      initial: shape.text,
      hint: 'Each line is a paragraph',
      multiline: true,
      fieldKey: const ValueKey('slide-text'),
    );
    if (result == null || result == shape.text) return;
    final slide = _slide;
    _edit((e) => e.setShapeText(slide, ref, result));
  }

  Future<void> _pickColor() async {
    const colors = ['000000', 'FFFFFF', '404040', 'C00000', 'FF0000', 'FFC000', 'FFFF00', '00B050', '0070C0', '7030A0'];
    final picked = await showGlassSheet<String>(
      context,
      (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Text colour', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final rgb in colors)
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.pop(sheet, rgb),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Color(int.parse('FF$rgb', radix: 16)),
                    shape: BoxShape.circle,
                    border: Border.all(color: sheet.palette.glassBorder, width: 1.5),
                  ),
                ),
              ),
          ]),
        ],
      ),
    );
    final ref = _selected;
    if (picked == null || ref == null) return;
    final slide = _slide;
    _edit((e) => e.setColor(slide, ref, picked));
  }

  Future<void> _pickFont() async {
    final picked = await showGlassSheet<String>(
      context,
      (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Font', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final font in const ['Calibri', 'Calibri Light', 'Arial', 'Times New Roman', 'Georgia', 'Verdana'])
              GlassChip(label: font, selected: false, onTap: () => Navigator.pop(sheet, font)),
          ]),
        ],
      ),
    );
    final ref = _selected;
    if (picked == null || ref == null) return;
    final slide = _slide;
    _edit((e) => e.setFont(slide, ref, picked));
  }

  void _panStart(int slide, Offset emu, double scale) {
    final shape = _selectedShape;
    if (slide != _slide || shape == null || shape.inGroup) return;
    final rect = SlideCanvas.rectsFor(_presentation, _presentation.slides[slide])[_presentation.slides[slide].shapes.indexOf(shape)];
    // The corner handle is drawn 28 px square at the bottom right.
    final handle = 28 / scale;
    _resizing = (emu.dx - (rect.x + rect.width)).abs() < handle && (emu.dy - (rect.y + rect.height)).abs() < handle;
    final inside = emu.dx >= rect.x && emu.dx <= rect.x + rect.width && emu.dy >= rect.y && emu.dy <= rect.y + rect.height;
    if (!_resizing && !inside) return;
    setState(() {
      _dragStart = rect;
      _dragRect = rect;
      _dragOrigin = emu;
    });
  }

  void _panUpdate(Offset emu) {
    final start = _dragStart;
    final origin = _dragOrigin;
    if (start == null || origin == null) return;
    final d = emu - origin;
    final min = (_presentation.slideWidth * 0.03).round();
    setState(() {
      _dragRect = _resizing
          ? EmuRect(start.x, start.y, (start.width + d.dx).round().clamp(min, 1 << 30), (start.height + d.dy).round().clamp(min, 1 << 30))
          : EmuRect((start.x + d.dx).round(), (start.y + d.dy).round(), start.width, start.height);
    });
  }

  void _panEnd() {
    final rect = _dragRect;
    final ref = _selected;
    final start = _dragStart;
    setState(() {
      _dragRect = null;
      _dragStart = null;
      _dragOrigin = null;
    });
    if (rect == null || ref == null || start == null) return;
    if (rect.x == start.x && rect.y == start.y && rect.width == start.width && rect.height == start.height) return;
    final slide = _slide;
    _edit((e) => e.setRect(slide, ref, rect));
  }

  // ---------------------------------------------------------------------------
  // Building

  @override
  Widget build(BuildContext context) {
    final pres = _presentation;
    if (_keys.length != pres.slides.length) _keys = List.generate(pres.slides.length, (_) => GlobalKey());
    widget.onStatus('${_editing ? 'Editing · ' : ''}${pres.slides.length} ${pres.slides.length == 1 ? 'slide' : 'slides'}');
    final p = context.palette;
    final locked = _editing && _selected != null;
    final list = PinchZoom(
      minZoom: 1,
      panHorizontally: true,
      vertical: _scroll,
      builder: (context, pinching) => ListView.separated(
        controller: _scroll,
        // A selected shape takes drags; tap outside it to scroll again.
        physics: pinching || locked ? const NeverScrollableScrollPhysics() : null,
        padding: EdgeInsets.fromLTRB(16, 8, 16, _editing ? 40 : 140),
        itemCount: pres.slides.length,
        separatorBuilder: (_, _) => const SizedBox(height: 18),
        itemBuilder: (context, i) => Column(
          key: _keys[i],
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: _editing && i == _slide ? Border.all(color: FileColors.powerpoint, width: 2) : null,
                boxShadow: [BoxShadow(color: FileColors.powerpoint.withValues(alpha: 0.18 * p.glowOpacity), blurRadius: 30)],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _editing
                    ? _editableSlide(i)
                    : GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          fullscreenDialog: true,
                          builder: (_) => PresentationScreen(presentation: pres, initialSlide: i),
                        )),
                        child: SlideCanvas(presentation: pres, slide: pres.slides[i]),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _editing && i == _slide ? FileColors.powerpoint : p.textMuted)),
          ],
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 84),
      child: _editing ? Column(children: [Expanded(child: list), _toolbar()]) : list,
    );
  }

  Widget _editableSlide(int i) {
    final pres = _presentation;
    final slide = pres.slides[i];
    final selectedHere = i == _slide ? _selectedShape : null;
    return AspectRatio(
      aspectRatio: pres.aspectRatio,
      child: LayoutBuilder(builder: (context, box) {
        final scale = box.maxWidth / pres.slideWidth;
        Offset toEmu(Offset local) => local / scale;
        EmuRect? outline;
        if (selectedHere != null) {
          outline = _dragRect ?? SlideCanvas.rectsFor(pres, slide)[slide.shapes.indexOf(selectedHere)];
        }
        final dragging = _dragRect != null && selectedHere != null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Measure drags from where the finger went down, so shapes follow it exactly.
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: (d) => _tap(i, toEmu(d.localPosition)),
          onPanStart: selectedHere == null ? null : (d) => _panStart(i, toEmu(d.localPosition), scale),
          onPanUpdate: selectedHere == null ? null : (d) => _panUpdate(toEmu(d.localPosition)),
          onPanEnd: selectedHere == null ? null : (_) => _panEnd(),
          child: Stack(
            children: [
              SlideCanvas(
                presentation: pres,
                slide: slide,
                editing: true,
                overrides: dragging ? {selectedHere.ref!: _dragRect!} : const {},
              ),
              if (outline != null) ...[
                Positioned(
                  left: outline.x * scale,
                  top: outline.y * scale,
                  width: outline.width * scale,
                  height: outline.height * scale,
                  child: IgnorePointer(
                    child: Container(
                      key: const ValueKey('selected-shape'),
                      decoration: BoxDecoration(border: Border.all(color: FileColors.powerpoint, width: 2)),
                    ),
                  ),
                ),
                if (!selectedHere!.inGroup)
                  Positioned(
                    left: (outline.x + outline.width) * scale - 14,
                    top: (outline.y + outline.height) * scale - 14,
                    child: IgnorePointer(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: FileColors.powerpoint, width: 3),
                        ),
                        child: const Icon(Icons.open_in_full_rounded, size: 14, color: FileColors.powerpoint),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      }),
    );
  }

  void _undo() {
    _selected = null;
    _edit((e) => e.undo());
  }

  Widget _toolbar() {
    final editor = widget.editor!;
    final shape = _selectedShape;
    final ref = _selected;
    final slide = _slide;
    final isText = shape != null && shape.kind != PptxShapeKind.picture;
    final run = isText ? shape.paragraphs.expand((p) => p.runs).firstOrNull : null;
    final align = isText && shape.paragraphs.isNotEmpty ? shape.paragraphs.first.align : 'l';
    final nextAlign = switch (align) { 'l' => 'ctr', 'ctr' => 'r', _ => 'l' };
    Widget button(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GlassIconButton(icon: icon, tooltip: tip, onPressed: onTap, size: 40, color: on ? FileColors.powerpoint : null),
        );
    final count = _presentation.slides.length;
    final buttons = shape == null
        ? [
            button(Icons.undo_rounded, 'Undo', editor.canUndo ? _undo : null),
            button(Icons.add_box_outlined, 'New slide', () => _edit((e) => _slide = e.addSlide(slide))),
            button(Icons.text_fields_rounded, 'Add text box', () {
              late int added;
              _edit((e) => added = e.addTextBox(slide, 'Text'));
              setState(() => _selected = added);
            }),
            button(Icons.copy_all_rounded, 'Duplicate slide', () => _edit((e) => _slide = e.duplicateSlide(slide))),
            button(Icons.arrow_upward_rounded, 'Move slide up', slide > 0 ? () => _edit((e) => e.moveSlide(slide, _slide = slide - 1)) : null),
            button(Icons.arrow_downward_rounded, 'Move slide down', slide < count - 1 ? () => _edit((e) => e.moveSlide(slide, _slide = slide + 1)) : null),
            button(Icons.delete_outline_rounded, 'Delete slide', count > 1 ? () => _edit((e) => e.deleteSlide(slide)) : null),
          ]
        : [
            button(Icons.undo_rounded, 'Undo', editor.canUndo ? _undo : null),
            if (isText) ...[
              button(Icons.edit_rounded, 'Edit text', _editText),
              button(Icons.format_bold_rounded, 'Bold', () => _edit((e) => e.setBold(slide, ref!, !(run?.bold ?? false))), on: run?.bold ?? false),
              button(Icons.format_italic_rounded, 'Italic', () => _edit((e) => e.setItalic(slide, ref!, !(run?.italic ?? false))), on: run?.italic ?? false),
              button(Icons.text_decrease_rounded, 'Smaller text', () => _edit((e) => e.scaleFontSize(slide, ref!, 0.85))),
              button(Icons.text_increase_rounded, 'Bigger text', () => _edit((e) => e.scaleFontSize(slide, ref!, 1.15))),
              button(Icons.format_color_text_rounded, 'Text colour', _pickColor),
              button(Icons.font_download_outlined, 'Font', _pickFont),
              button(
                switch (align) { 'ctr' => Icons.format_align_center_rounded, 'r' => Icons.format_align_right_rounded, _ => Icons.format_align_left_rounded },
                'Alignment',
                () => _edit((e) => e.setAlignment(slide, ref!, nextAlign)),
              ),
            ],
            button(Icons.delete_outline_rounded, 'Delete shape', () {
              _edit((e) => e.deleteShape(slide, ref!));
              setState(() => _selected = null);
            }),
          ];
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(child: ListView(scrollDirection: Axis.horizontal, children: buttons)),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: () {
                setState(() => _selected = null);
                widget.onDoneEditing?.call();
              },
              style: FilledButton.styleFrom(backgroundColor: FileColors.powerpoint, foregroundColor: Colors.white),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws one slide at any size by scaling EMU coordinates.
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({super.key, required this.presentation, required this.slide, this.overrides = const {}, this.editing = false});

  final PptxPresentation presentation;
  final PptxSlide slide;

  /// Positions to draw instead of the stored ones, by shape ref (while a
  /// shape is being dragged).
  final Map<int, EmuRect> overrides;

  /// Shows empty placeholders as "Tap to add text" boxes.
  final bool editing;

  static const _emuPerPt = 12700;

  /// Where each shape of [slide] is drawn, in EMU, in the order of its shapes.
  static List<EmuRect> rectsFor(PptxPresentation presentation, PptxSlide slide) {
    final w = presentation.slideWidth.toDouble();
    final h = presentation.slideHeight.toDouble();
    var autoTop = 0.08;
    final out = <EmuRect>[];
    for (final shape in slide.shapes) {
      var rect = shape.rect;
      if (rect == null) {
        // Placeholder positions inherited from the layout: approximate them.
        final isTitle = shape.kind == PptxShapeKind.title;
        rect = EmuRect((w * 0.07).round(), (h * (isTitle ? 0.06 : autoTop)).round(), (w * 0.86).round(), (h * (isTitle ? 0.18 : 0.62)).round());
        autoTop = isTitle ? 0.28 : autoTop + 0.62;
      }
      out.add(rect);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: presentation.aspectRatio,
      child: LayoutBuilder(builder: (context, box) {
        final scale = box.maxWidth / presentation.slideWidth;
        final rects = rectsFor(presentation, slide);
        final children = <Widget>[];
        for (var i = 0; i < slide.shapes.length; i++) {
          final shape = slide.shapes[i];
          final rect = overrides[shape.ref] ?? rects[i];
          final r = Rect.fromLTWH(rect.x * scale, rect.y * scale, rect.width * scale, rect.height * scale);
          final empty = shape.kind != PptxShapeKind.picture && shape.text.trim().isEmpty;
          if (empty && shape.placeholder) {
            if (!editing) continue;
            children.add(Positioned.fromRect(rect: r, child: _hint(shape, scale)));
            continue;
          }
          Widget child = _shape(shape, scale, r.width);
          if (shape.rotation != 0) child = Transform.rotate(angle: shape.rotation * math.pi / 180, child: child);
          children.add(Positioned.fromRect(rect: r, child: child));
        }
        final background = slide.backgroundFill ??
            (slide.backgroundImage != null
                ? PptxFill.picture(slide.backgroundImage!)
                : slide.background != null
                    ? PptxFill.solid(PptxColor(slide.background!))
                    : null);
        return ClipRect(
          child: Container(
            decoration: ShapeFill.decoration(background, scale) ?? const BoxDecoration(color: Colors.white),
            child: Stack(clipBehavior: Clip.hardEdge, children: children),
          ),
        );
      }),
    );
  }

  Widget _hint(PptxShape shape, double scale) {
    final title = shape.kind == PptxShapeKind.title;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFF9CA3AF), width: 1)),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          title ? 'Tap to add title' : 'Tap to add text',
          style: TextStyle(fontSize: (title ? 36 : 22) * _emuPerPt * scale, color: const Color(0xFF6B7280)),
        ),
      ),
    );
  }

  Widget _shape(PptxShape shape, double scale, double width) {
    if (shape.kind == PptxShapeKind.picture && shape.imageBytes != null) {
      final picture = ShapeFill(fill: shape.fillStyle ?? PptxFill.picture(shape.imageBytes!), line: shape.line, geometry: shape.geometry, scale: scale);
      // A mirrored picture mirrors the image too, not just its outline.
      return shape.flipH || shape.flipV ? Transform.flip(flipX: shape.flipH, flipY: shape.flipV, child: picture) : picture;
    }
    final defaultPt = switch (shape.kind) {
      PptxShapeKind.title => 40.0,
      PptxShapeKind.body => 24.0,
      _ => 18.0,
    };
    final table = shape.table;
    if (table != null) return _table(table, scale);
    final paragraphs = shape.paragraphs;
    final body = ShapeFill(
      fill: shape.fillStyle ?? (shape.fill == null ? null : PptxFill.solid(PptxColor(shape.fill!))),
      line: shape.line,
      geometry: shape.geometry,
      flipH: shape.flipH,
      flipV: shape.flipV,
      scale: scale,
    );
    if (paragraphs.every((p) => p.text.trim().isEmpty)) return body;
    return Stack(fit: StackFit.expand, children: [body, _text(shape, scale, width, defaultPt)]);
  }

  /// A table, each cell placed on the grid so merged cells can span.
  Widget _table(PptxTable table, double scale) {
    final xs = [0.0];
    for (final w in table.columns) {
      xs.add(xs.last + w * scale);
    }
    final ys = [0.0];
    for (final r in table.rows) {
      ys.add(ys.last + r.height * scale);
    }
    BorderSide side(PptxLine? l) => l == null ? BorderSide.none : BorderSide(color: ShapeFill.color(l.color), width: math.max(0.5, l.widthEmu * scale));
    final cells = <Widget>[];
    for (var r = 0; r < table.rows.length; r++) {
      var col = 0;
      for (final cell in table.rows[r].cells) {
        final c = col;
        col++;
        if (cell.merged || c >= table.columns.length) continue;
        final right = math.min(c + cell.columnSpan, table.columns.length);
        final bottom = math.min(r + cell.rowSpan, table.rows.length);
        final rect = Rect.fromLTRB(xs[c], ys[r], xs[right], ys[bottom]);
        cells.add(Positioned.fromRect(
          rect: rect,
          child: DecoratedBox(
            decoration: ShapeFill.decoration(cell.fill, scale, border: Border(left: side(cell.left), right: side(cell.right), top: side(cell.top), bottom: side(cell.bottom))) ??
                const BoxDecoration(),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 91440 * scale, vertical: 45720 * scale),
              child: _paragraphs(cell.paragraphs, PptxShapeKind.text, cell.anchor, scale, rect.width - 2 * 91440 * scale, 18),
            ),
          ),
        ));
      }
    }
    return Stack(clipBehavior: Clip.none, children: cells);
  }

  Widget _text(PptxShape shape, double scale, double width, double defaultPt) => Padding(
        padding: EdgeInsets.all(91440 * scale), // 0.1in text inset
        child: _paragraphs(shape.paragraphs, shape.kind, shape.anchor, scale, width - 2 * 91440 * scale, defaultPt),
      );

  Widget _paragraphs(List<PptxParagraph> paragraphs, PptxShapeKind kind, String anchor, double scale, double width, double defaultPt) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: switch (anchor) {
        'ctr' => Alignment.centerLeft,
        'b' => Alignment.bottomLeft,
        _ => Alignment.topLeft,
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width.clamp(20, double.infinity)),
        child: Column(
          // Stretch so centred and right-aligned paragraphs line up across the box.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final para in paragraphs)
              Padding(
                padding: EdgeInsets.only(left: para.level * 28 * _emuPerPt * scale),
                child: Text.rich(
                  TextSpan(children: [
                    if (para.bullet && para.text.trim().isNotEmpty) const TextSpan(text: '•  '),
                    for (final run in para.runs)
                      TextSpan(
                        text: run.text,
                        style: TextStyle(
                          fontSize: (run.fontSizePt ?? defaultPt) * _emuPerPt * scale,
                          fontWeight: run.bold || kind == PptxShapeKind.title ? FontWeight.w700 : FontWeight.w400,
                          fontStyle: run.italic ? FontStyle.italic : null,
                          color: _hex(run.color),
                        ),
                      ),
                  ]),
                  textAlign: switch (para.align) {
                    'ctr' => TextAlign.center,
                    'r' => TextAlign.right,
                    'just' => TextAlign.justify,
                    _ => TextAlign.left,
                  },
                  style: TextStyle(
                    fontFamily: 'Calibri',
                    fontFamilyFallback: officeFontFallback,
                    fontSize: defaultPt * _emuPerPt * scale,
                    height: 1.15,
                    color: const Color(0xFF1F2937),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Color? _hex(String? hex) {
    if (hex == null || hex.length != 6) return null;
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }
}

/// Paints a slide shape's fill (colour, gradient or picture) and outline in
/// its outline's shape. [scale] is pixels per EMU.
class ShapeFill extends StatelessWidget {
  const ShapeFill({super.key, required this.fill, required this.scale, this.line, this.geometry, this.flipH = false, this.flipV = false});

  final PptxFill? fill;
  final PptxLine? line;
  final PptxGeometry? geometry;
  final bool flipH;
  final bool flipV;
  final double scale;

  static const _emuPerPixel = 9525;

  static Color color(PptxColor c) => Color((((c.alpha * 255).round().clamp(0, 255)) << 24) | (int.tryParse(c.hex, radix: 16) ?? 0));

  /// The fill as a box decoration, for rectangles and slide backgrounds.
  static BoxDecoration? decoration(PptxFill? fill, double scale, {Border? border}) {
    if (fill == null) return border == null ? null : BoxDecoration(border: border);
    final image = fill.image;
    return BoxDecoration(
      color: fill.color == null ? null : color(fill.color!),
      gradient: gradient(fill),
      border: border,
      image: image == null
          ? null
          : DecorationImage(
              image: MemoryImage(image),
              fit: fill.tile ? BoxFit.none : BoxFit.fill,
              repeat: fill.tile ? ImageRepeat.repeat : ImageRepeat.noRepeat,
              alignment: fill.tile ? Alignment.topLeft : Alignment.center,
              // Tiles keep the picture's size (96 pixels to the inch).
              scale: fill.tile ? 1 / (_emuPerPixel * scale).clamp(0.01, 100) : 1,
              colorFilter: fill.colorMatrix == null ? null : ColorFilter.matrix(fill.colorMatrix!),
              onError: (_, _) {},
            ),
    );
  }

  static Gradient? gradient(PptxFill fill) {
    if (fill.stops.length < 2) return null;
    final colors = [for (final s in fill.stops) color(s.color)];
    final stops = [for (final s in fill.stops) s.position];
    if (fill.radial) {
      return RadialGradient(center: Alignment(fill.centerX * 2 - 1, fill.centerY * 2 - 1), radius: 0.75, colors: colors, stops: stops);
    }
    final a = fill.angle * math.pi / 180;
    final dx = math.cos(a), dy = math.sin(a);
    // Reach the corners along the gradient's direction.
    final k = 1 / math.max(dx.abs(), dy.abs());
    return LinearGradient(begin: Alignment(-dx * k, -dy * k), end: Alignment(dx * k, dy * k), colors: colors, stops: stops);
  }

  @override
  Widget build(BuildContext context) {
    final g = geometry;
    final stroke = line == null ? null : (color(line!.color), math.max(0.5, line!.widthEmu * scale));
    if (g == null || (g.isRect && !g.isLine)) {
      return DecoratedBox(
        decoration: decoration(fill, scale, border: stroke == null ? null : Border.all(color: stroke.$1, width: stroke.$2)) ?? const BoxDecoration(),
        child: const SizedBox.expand(),
      );
    }
    final image = fill?.image;
    return Stack(fit: StackFit.expand, clipBehavior: Clip.none, children: [
      if (image != null && !g.isLine)
        ClipPath(
          clipper: _GeometryClipper(g, flipH, flipV),
          child: DecoratedBox(decoration: decoration(fill, scale)!, child: const SizedBox.expand()),
        ),
      CustomPaint(painter: _GeometryPainter(g, image == null ? fill : null, stroke, flipH, flipV, arrows: (line?.arrowAtStart ?? false, line?.arrowAtEnd ?? false))),
    ]);
  }
}

Path _geometryPath(PptxGeometry g, Size size, bool flipH, bool flipV, {bool forFill = true}) {
  final path = Path();
  for (final gp in g.paths(size.width, size.height)) {
    if (forFill ? !gp.fill : !gp.stroke) continue;
    final sub = Path();
    for (final op in gp.ops) {
      switch (op) {
        case MoveTo(:final x, :final y):
          sub.moveTo(x, y);
        case LineTo(:final x, :final y):
          sub.lineTo(x, y);
        case CubicTo(:final x1, :final y1, :final x2, :final y2, :final x, :final y):
          sub.cubicTo(x1, y1, x2, y2, x, y);
        case ClosePath():
          sub.close();
      }
    }
    path.addPath(sub, Offset.zero);
  }
  if (!flipH && !flipV) return path;
  final m = Matrix4.identity()
    ..translateByDouble(flipH ? size.width : 0, flipV ? size.height : 0, 0, 1)
    ..scaleByDouble(flipH ? -1 : 1, flipV ? -1 : 1, 1, 1);
  return path.transform(m.storage);
}

class _GeometryClipper extends CustomClipper<Path> {
  _GeometryClipper(this.geometry, this.flipH, this.flipV);

  final PptxGeometry geometry;
  final bool flipH;
  final bool flipV;

  @override
  Path getClip(Size size) => _geometryPath(geometry, size, flipH, flipV);

  @override
  bool shouldReclip(_GeometryClipper old) => old.geometry != geometry || old.flipH != flipH || old.flipV != flipV;
}

class _GeometryPainter extends CustomPainter {
  _GeometryPainter(this.geometry, this.fill, this.stroke, this.flipH, this.flipV, {this.arrows = (false, false)});

  final (bool, bool) arrows;

  final PptxGeometry geometry;
  final PptxFill? fill;
  final (Color, double)? stroke;
  final bool flipH;
  final bool flipV;

  @override
  void paint(Canvas canvas, Size size) {
    final f = fill;
    if (f != null && !geometry.isLine) {
      final paint = Paint()..style = PaintingStyle.fill;
      final gradient = ShapeFill.gradient(f);
      if (gradient != null) {
        paint.shader = gradient.createShader(Offset.zero & size);
      } else if (f.color != null) {
        paint.color = ShapeFill.color(f.color!);
      } else {
        paint.color = const Color(0x00000000);
      }
      canvas.drawPath(_geometryPath(geometry, size, flipH, flipV), paint);
    }
    final s = stroke;
    if (s != null) {
      canvas.drawPath(
        _geometryPath(geometry, size, flipH, flipV, forFill: false),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = s.$1
          ..strokeWidth = s.$2,
      );
      if (geometry.isLine && (arrows.$1 || arrows.$2)) _arrowheads(canvas, size, s);
    }
  }

  /// Triangles at the ends of a line, pointing along its first and last parts.
  void _arrowheads(Canvas canvas, Size size, (Color, double) s) {
    final points = <Offset>[];
    for (final gp in geometry.paths(size.width, size.height)) {
      for (final op in gp.ops) {
        switch (op) {
          case MoveTo(:final x, :final y) || LineTo(:final x, :final y):
            points.add(Offset(x, y));
          case CubicTo(:final x1, :final y1, :final x2, :final y2, :final x, :final y):
            points
              ..add(Offset(x1, y1))
              ..add(Offset(x2, y2))
              ..add(Offset(x, y));
          case ClosePath():
        }
      }
    }
    Offset flip(Offset p) => Offset(flipH ? size.width - p.dx : p.dx, flipV ? size.height - p.dy : p.dy);
    final pts = [for (final p in points) flip(p)];
    if (pts.length < 2) return;
    final paint = Paint()..color = s.$1;
    final len = math.max(6.0, s.$2 * 3.5);
    void head(Offset tip, Offset from) {
      final d = tip - from;
      if (d.distance == 0) return;
      final u = d / d.distance;
      final n = Offset(-u.dy, u.dx);
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(tip.dx - u.dx * len + n.dx * len / 2, tip.dy - u.dy * len + n.dy * len / 2)
          ..lineTo(tip.dx - u.dx * len - n.dx * len / 2, tip.dy - u.dy * len - n.dy * len / 2)
          ..close(),
        paint,
      );
    }

    if (arrows.$1) head(pts.first, pts.firstWhere((p) => p != pts.first, orElse: () => pts.first));
    if (arrows.$2) head(pts.last, pts.lastWhere((p) => p != pts.last, orElse: () => pts.last));
  }

  @override
  bool shouldRepaint(_GeometryPainter old) =>
      old.geometry != geometry || old.fill != fill || old.stroke != stroke || old.flipH != flipH || old.flipV != flipV || old.arrows != arrows;
}

/// Full-screen presenter: swipe between slides, tap to close.
class PresentationScreen extends StatefulWidget {
  const PresentationScreen({super.key, required this.presentation, required this.initialSlide});

  final PptxPresentation presentation;
  final int initialSlide;

  @override
  State<PresentationScreen> createState() => _PresentationScreenState();
}

class _PresentationScreenState extends State<PresentationScreen> {
  late final _pages = PageController(initialPage: widget.initialSlide);
  late int _index = widget.initialSlide;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.presentation.slides;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: slides.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _ZoomableSlide(presentation: widget.presentation, slide: slides[i]),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: GlassIconButton(icon: Icons.close_rounded, tooltip: 'Exit presentation', onPressed: () => Navigator.pop(context), color: Colors.white),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('${_index + 1} / ${slides.length}', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One presented slide that can be pinched to zoom and then panned around.
class _ZoomableSlide extends StatefulWidget {
  const _ZoomableSlide({required this.presentation, required this.slide});

  final PptxPresentation presentation;
  final PptxSlide slide;

  @override
  State<_ZoomableSlide> createState() => _ZoomableSlideState();
}

class _ZoomableSlideState extends State<_ZoomableSlide> {
  final _vertical = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PinchZoom(
      minZoom: 1,
      panHorizontally: true,
      vertical: _vertical,
      builder: (context, pinching) => LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          controller: _vertical,
          physics: pinching ? const NeverScrollableScrollPhysics() : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Center(child: SlideCanvas(presentation: widget.presentation, slide: widget.slide)),
          ),
        ),
      ),
    );
  }
}
