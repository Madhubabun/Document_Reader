import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Pinch-to-zoom for document views that scroll on their own.
///
/// The child is laid out at the viewport size divided by the zoom and then
/// painted scaled up, so a scrolling list inside keeps building only the
/// rows on screen and text stays crisp. Two-finger pinches are read with a
/// raw [Listener], so they never fight the child's scroll gestures; while a
/// pinch is in progress [builder] gets `pinching: true` so the child can
/// pause its own scrolling.
///
/// By default content reflows to the zoomed width, which suits text and
/// grids that scroll sideways themselves. With [panHorizontally] the content
/// keeps its width and the zoomed view scrolls left and right instead, which
/// suits slides.
class PinchZoom extends StatefulWidget {
  const PinchZoom({super.key, required this.builder, this.minZoom = 0.5, this.maxZoom = 4, this.vertical, this.horizontal, this.panHorizontally = false});

  final Widget Function(BuildContext context, bool pinching) builder;
  final double minZoom;
  final double maxZoom;

  /// Scroll controllers to adjust so the point between the fingers stays put.
  final ScrollController? vertical;
  final ScrollController? horizontal;
  final bool panHorizontally;

  @override
  State<PinchZoom> createState() => _PinchZoomState();
}

class _PinchZoomState extends State<PinchZoom> {
  final _ownHorizontal = ScrollController();
  final _pointers = <int, Offset>{};
  double _zoom = 1;
  double? _startZoom;
  double? _startDistance;

  ScrollController? get _horizontal => widget.horizontal ?? (widget.panHorizontally ? _ownHorizontal : null);

  @override
  void dispose() {
    _ownHorizontal.dispose();
    super.dispose();
  }

  double _distance() {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  Offset _focal() {
    final points = _pointers.values.take(2).toList();
    return (points[0] + points[1]) / 2;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      setState(() {
        _startZoom = _zoom;
        _startDistance = _distance();
      });
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final startDistance = _startDistance;
    if (_pointers.length < 2 || startDistance == null || startDistance < 1) return;
    final next = (_startZoom! * _distance() / startDistance).clamp(widget.minZoom, widget.maxZoom);
    if ((next - _zoom).abs() < 0.005) return;
    _apply(next, _focal());
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _startDistance != null) {
      setState(() {
        _startDistance = null;
        _startZoom = null;
      });
    }
  }

  /// Changes the zoom, keeping the content under [focal] in place.
  void _apply(double next, Offset focal) {
    final old = _zoom;
    void keep(ScrollController? c, double f) {
      if (c == null || !c.hasClients) return;
      // Content coordinate under the finger, which must stay under the finger.
      final content = c.offset + f / old;
      final target = content - f / next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!c.hasClients) return;
        final pos = c.position;
        c.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
      });
    }

    keep(widget.vertical, focal.dy);
    if (widget.panHorizontally) {
      // The outer horizontal scroll is in screen units, not content units.
      final c = _horizontal!;
      if (c.hasClients) {
        final target = (c.offset + focal.dx) * next / old - focal.dx;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (c.hasClients) c.jumpTo(target.clamp(c.position.minScrollExtent, c.position.maxScrollExtent));
        });
      }
    } else {
      keep(widget.horizontal, focal.dx);
    }
    setState(() => _zoom = next);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: ClipRect(
        child: widget.panHorizontally ? _panning() : ZoomBox(zoom: _zoom, child: widget.builder(context, _startDistance != null)),
      ),
    );
  }
}

extension on _PinchZoomState {
  Widget _panning() => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      controller: _horizontal,
      scrollDirection: Axis.horizontal,
      physics: _zoom <= 1 || _startDistance != null ? const NeverScrollableScrollPhysics() : null,
      child: SizedBox(
        width: box.maxWidth * (_zoom < 1 ? 1 : _zoom),
        height: box.maxHeight,
        child: ZoomBox(zoom: _zoom < 1 ? 1 : _zoom, child: widget.builder(context, _startDistance != null)),
      ),
    ),
  );
}

/// Lays its child out at its own size divided by [zoom] and paints it scaled
/// by [zoom], so the child fills the same box at a different magnification.
class ZoomBox extends SingleChildRenderObjectWidget {
  const ZoomBox({super.key, required this.zoom, super.child});

  final double zoom;

  @override
  RenderZoomBox createRenderObject(BuildContext context) => RenderZoomBox(zoom);

  @override
  void updateRenderObject(BuildContext context, RenderZoomBox renderObject) => renderObject.zoom = zoom;
}

class RenderZoomBox extends RenderProxyBox {
  RenderZoomBox(this._zoom);

  double _zoom;

  set zoom(double value) {
    if (value == _zoom) return;
    _zoom = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = constraints;
    final child = this.child;
    if (child == null) {
      size = c.smallest;
      return;
    }
    BoxConstraints scaled(BoxConstraints b) => BoxConstraints(
      minWidth: b.minWidth / _zoom,
      maxWidth: b.maxWidth.isFinite ? b.maxWidth / _zoom : double.infinity,
      minHeight: b.minHeight / _zoom,
      maxHeight: b.maxHeight.isFinite ? b.maxHeight / _zoom : double.infinity,
    );
    child.layout(scaled(c), parentUsesSize: true);
    size = c.constrain(child.size * _zoom);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_zoom == 1) {
      context.paintChild(child, offset);
      return;
    }
    context.pushTransform(needsCompositing, offset, Matrix4.diagonal3Values(_zoom, _zoom, 1), (ctx, o) => ctx.paintChild(child, o));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintTransform(
      transform: Matrix4.diagonal3Values(_zoom, _zoom, 1),
      position: position,
      hitTest: (result, p) => child.hitTest(result, position: p),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.scaleByDouble(_zoom, _zoom, 1, 1);
}
