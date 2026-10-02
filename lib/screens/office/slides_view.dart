import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ooxml/ooxml_editor.dart';
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
          children.add(Positioned.fromRect(rect: r, child: _shape(shape, scale, r.width)));
        }
        final bgImage = slide.backgroundImage;
        return Container(
          decoration: BoxDecoration(
            color: _hex(slide.background) ?? Colors.white,
            image: bgImage == null ? null : DecorationImage(image: MemoryImage(bgImage), fit: BoxFit.fill),
          ),
          child: Stack(clipBehavior: Clip.hardEdge, children: children),
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
      return Image.memory(shape.imageBytes!, fit: BoxFit.fill, errorBuilder: (_, _, _) => const SizedBox.shrink());
    }
    final defaultPt = switch (shape.kind) {
      PptxShapeKind.title => 40.0,
      PptxShapeKind.body => 24.0,
      _ => 18.0,
    };
    final paragraphs = shape.paragraphs;
    return Container(
      color: _hex(shape.fill),
      padding: EdgeInsets.all(91440 * scale), // 0.1in text inset
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: switch (shape.anchor) {
          'ctr' => Alignment.centerLeft,
          'b' => Alignment.bottomLeft,
          _ => Alignment.topLeft,
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: (width - 2 * 91440 * scale).clamp(20, double.infinity)),
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
                            fontWeight: run.bold || shape.kind == PptxShapeKind.title ? FontWeight.w700 : FontWeight.w400,
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
      ),
    );
  }

  static Color? _hex(String? hex) {
    if (hex == null || hex.length != 6) return null;
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }
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
