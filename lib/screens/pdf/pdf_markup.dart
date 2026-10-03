import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/pdf_edits.dart';
import '../../services/pdf_text_lines.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';

enum MarkupTool { scroll, highlight, underline, strikeout, pen, marker }

extension MarkupToolInfo on MarkupTool {
  String get label => switch (this) {
        MarkupTool.scroll => 'Scroll',
        MarkupTool.highlight => 'Highlight',
        MarkupTool.underline => 'Underline',
        MarkupTool.strikeout => 'Strike',
        MarkupTool.pen => 'Pen',
        MarkupTool.marker => 'Marker',
      };

  IconData get icon => switch (this) {
        MarkupTool.scroll => Icons.pan_tool_outlined,
        MarkupTool.highlight => Icons.highlight_rounded,
        MarkupTool.underline => Icons.format_underlined_rounded,
        MarkupTool.strikeout => Icons.format_strikethrough_rounded,
        MarkupTool.pen => Icons.edit_rounded,
        MarkupTool.marker => Icons.brush_rounded,
      };

  bool get isText => this == MarkupTool.highlight || this == MarkupTool.underline || this == MarkupTool.strikeout;

  /// Colours offered for the tool, 0xAARRGGBB; the first is the default.
  List<int> get colors => switch (this) {
        MarkupTool.scroll => const [],
        MarkupTool.highlight || MarkupTool.marker => const [0xFFFFEB3B, 0xFF69F0AE, 0xFFFF80AB, 0xFF80D8FF],
        _ => const [0xFFE53935, 0xFF1E63D6, 0xFF111111, 0xFF2E7D32],
      };
}

/// Annotations drawn but not yet written into the file.
class MarkupController extends ChangeNotifier {
  MarkupTool _tool = MarkupTool.highlight;
  final _colors = <MarkupTool, int>{};
  final edits = <PdfEdit>[];

  /// A stroke or text selection in progress.
  PdfEdit? live;

  MarkupTool get tool => _tool;
  set tool(MarkupTool value) {
    _tool = value;
    notifyListeners();
  }

  int colorOf(MarkupTool t) => _colors[t] ?? (t.colors.isEmpty ? 0 : t.colors.first);
  int get color => colorOf(_tool);
  set color(int value) {
    _colors[_tool] = value;
    notifyListeners();
  }

  void setLive(PdfEdit? edit) {
    live = edit;
    notifyListeners();
  }

  void commitLive() {
    final edit = live;
    live = null;
    if (edit != null) edits.add(edit);
    notifyListeners();
  }

  void undo() {
    if (edits.isNotEmpty) edits.removeLast();
    notifyListeners();
  }

  void clear() {
    edits.clear();
    live = null;
    notifyListeners();
  }
}

/// Pen width as a fraction of the page width, and the marker's.
const penWidth = 0.004;
const markerWidth = 0.022;
const markerOpacity = 0.4;

/// Draws a page's pending annotations and, when a drawing tool is chosen,
/// turns drags on the page into new ones.
class MarkupLayer extends StatefulWidget {
  const MarkupLayer({super.key, required this.page, required this.pageSize, required this.controller, required this.onNoText});

  final PdfPage page;
  final Size pageSize;
  final MarkupController controller;

  /// Called when a text tool is dragged where there is no text.
  final VoidCallback onNoText;

  @override
  State<MarkupLayer> createState() => _MarkupLayerState();
}

class _MarkupLayerState extends State<MarkupLayer> {
  /// The page's characters, loaded on the first text drag.
  static final _chars = Expando<Future<PageChars>>();
  PageChars? _text;
  int? _anchor;
  bool _cancelled = false;

  /// Where a text drag started while the characters were still loading.
  Offset? _pending;

  MarkupController get c => widget.controller;
  int get pageNumber => widget.page.pageNumber;

  Offset _fraction(Offset local) => Offset(
        (local.dx / widget.pageSize.width).clamp(0.0, 1.0),
        (local.dy / widget.pageSize.height).clamp(0.0, 1.0),
      );

  Future<PageChars> _loadChars() {
    final page = widget.page;
    return _chars[page] ??= page.loadStructuredText().then((text) {
      return PageChars(
        [
          for (final r in text.charRects) r.toRect(page: page),
        ],
        Size(page.width, page.height),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    // Start loading early so the first highlight follows the finger.
    if (c.tool.isText) _loadChars().then((t) => _text = t, onError: (_) {});
  }

  void _start(Offset local) {
    final f = _fraction(local);
    _cancelled = false;
    _anchor = null;
    _pending = null;
    final tool = c.tool;
    if (tool == MarkupTool.pen || tool == MarkupTool.marker) {
      c.setLive(InkEdit(
        pageNumber,
        strokes: [
          [f],
        ],
        color: c.color,
        width: tool == MarkupTool.pen ? penWidth : markerWidth,
        opacity: tool == MarkupTool.pen ? 1 : markerOpacity,
      ));
      return;
    }
    final text = _text;
    if (text == null) {
      // Still loading: anchor the drag once the characters are in.
      _pending = f;
      _loadChars().then((t) {
        _text = t;
        final start = _pending;
        if (!mounted || start == null || _cancelled) return;
        _pending = null;
        _anchorAt(start);
      }, onError: (_) {
        if (!mounted || _pending == null) return;
        _pending = null;
        _cancelled = true;
        widget.onNoText();
      });
      return;
    }
    _anchorAt(f);
  }

  void _anchorAt(Offset f) {
    _anchor = _text!.nearest(f);
    if (_anchor == null) {
      _cancelled = true;
      widget.onNoText();
      return;
    }
    _select(_anchor!);
  }

  void _select(int end) {
    final kind = switch (c.tool) {
      MarkupTool.underline => MarkupKind.underline,
      MarkupTool.strikeout => MarkupKind.strikeout,
      _ => MarkupKind.highlight,
    };
    c.setLive(MarkupEdit(pageNumber, kind: kind, lines: _text!.lines(_anchor!, end), color: c.color));
  }

  void _update(Offset local) {
    if (_cancelled) return;
    final f = _fraction(local);
    final live = c.live;
    if (live is InkEdit) {
      final points = live.strokes.single;
      // Skip points closer than half a pen width to keep files small.
      if ((points.last - f).distance < 0.002) return;
      c.setLive(InkEdit(pageNumber, strokes: [
        [...points, f],
      ], color: live.color, width: live.width, opacity: live.opacity));
    } else if (live is MarkupEdit && _text != null && _anchor != null) {
      final end = _text!.nearest(f, reach: 60);
      if (end != null) _select(end);
    }
  }

  void _end() {
    _pending = null;
    if (_cancelled) return;
    final live = c.live;
    if (live is MarkupEdit && live.lines.isEmpty) {
      c.setLive(null);
      return;
    }
    c.commitLive();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final paint = CustomPaint(
          size: widget.pageSize,
          painter: _MarkupPainter([
            for (final e in c.edits)
              if (e.pageNumber == pageNumber) e,
            if (c.live?.pageNumber == pageNumber) c.live!,
          ]),
        );
        if (c.tool == MarkupTool.scroll) return IgnorePointer(child: paint);
        if (c.tool.isText && _text == null) _loadChars().then((t) => _text = t, onError: (_) {});
        return GestureDetector(
          key: ValueKey('markup-layer-$pageNumber'),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) => _start(d.localPosition),
          onPanUpdate: (d) => _update(d.localPosition),
          onPanEnd: (_) => _end(),
          onPanCancel: () {
            if (c.live?.pageNumber == pageNumber) c.setLive(null);
          },
          child: paint,
        );
      },
    );
  }
}

class _MarkupPainter extends CustomPainter {
  _MarkupPainter(this.edits);

  final List<PdfEdit> edits;

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in edits) {
      switch (e) {
        case MarkupEdit():
          final color = Color(e.color);
          for (final f in e.lines) {
            final r = Rect.fromLTRB(f.left * size.width, f.top * size.height, f.right * size.width, f.bottom * size.height);
            switch (e.kind) {
              case MarkupKind.highlight:
                canvas.drawRect(r, Paint()..color = color.withValues(alpha: 0.45));
              case MarkupKind.underline || MarkupKind.strikeout:
                final y = e.kind == MarkupKind.underline ? r.bottom - r.height * 0.08 : r.bottom - r.height * 0.45;
                canvas.drawLine(
                  Offset(r.left, y),
                  Offset(r.right, y),
                  Paint()
                    ..color = color
                    ..strokeWidth = (r.height / 14).clamp(1.0, 6.0),
                );
            }
          }
        case InkEdit():
          final paint = Paint()
            ..color = Color(e.color).withValues(alpha: e.opacity)
            ..strokeWidth = e.width * size.width
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round;
          for (final stroke in e.strokes) {
            if (stroke.length == 1) {
              canvas.drawCircle(Offset(stroke.first.dx * size.width, stroke.first.dy * size.height), paint.strokeWidth / 2, Paint()..color = paint.color);
              continue;
            }
            final path = Path()..moveTo(stroke.first.dx * size.width, stroke.first.dy * size.height);
            for (final p in stroke.skip(1)) {
              path.lineTo(p.dx * size.width, p.dy * size.height);
            }
            canvas.drawPath(path, paint);
          }
        case ImageEdit() || FieldEdit() || TextLayerEdit():
          break;
      }
    }
  }

  @override
  bool shouldRepaint(_MarkupPainter old) => true;
}

/// Tools, colours, undo, cancel and save for annotating.
class MarkupBar extends StatelessWidget {
  const MarkupBar({super.key, required this.controller, required this.busy, required this.onCancel, required this.onSave});

  final MarkupController controller;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onSave;

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
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final tool = controller.tool;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      for (final t in MarkupTool.values)
                        Tooltip(
                          message: t.label,
                          child: InkWell(
                            key: ValueKey('tool-${t.name}'),
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => controller.tool = t,
                            child: Container(
                              width: 46,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              decoration: t == tool
                                  ? BoxDecoration(
                                      borderRadius: BorderRadius.circular(14),
                                      color: p.accent.withValues(alpha: 0.16),
                                      border: Border.all(color: p.accent.withValues(alpha: 0.5)),
                                    )
                                  : null,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(t.icon, size: 21, color: t == tool ? p.accent : p.text),
                                  const SizedBox(height: 2),
                                  Text(t.label, style: TextStyle(fontSize: 9.5, color: t == tool ? p.accent : p.textMuted)),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 34,
                    child: tool == MarkupTool.scroll
                        ? Center(child: Text('Scroll and zoom freely. Pick a tool to mark up.', style: TextStyle(color: p.textMuted, fontSize: 12.5)))
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (final color in tool.colors)
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 7),
                                  child: Semantics(
                                    button: true,
                                    selected: controller.color == color,
                                    label: 'Colour',
                                    child: GestureDetector(
                                      onTap: () => controller.color = color,
                                      child: Container(
                                        width: 28,
                                        height: 28,
                                        decoration: BoxDecoration(
                                          color: Color(color),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: controller.color == color ? p.text : Colors.white24, width: controller.color == color ? 3 : 1.5),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Undo',
                        onPressed: busy || controller.edits.isEmpty ? null : controller.undo,
                        icon: const Icon(Icons.undo_rounded),
                      ),
                      const SizedBox(width: 4),
                      Expanded(child: OutlinedButton(onPressed: busy ? null : onCancel, child: const Text('Cancel'))),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          key: const Key('save-markup'),
                          onPressed: busy || controller.edits.isEmpty ? null : onSave,
                          child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
