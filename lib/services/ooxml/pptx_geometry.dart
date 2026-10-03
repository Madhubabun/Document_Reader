import 'dart:math' as math;

import 'package:xml/xml.dart';

import 'xml_utils.dart';

/// One step of a shape outline, in points of the shape's own box.
sealed class PathOp {
  const PathOp();
}

class MoveTo extends PathOp {
  const MoveTo(this.x, this.y);
  final double x, y;
}

class LineTo extends PathOp {
  const LineTo(this.x, this.y);
  final double x, y;
}

class CubicTo extends PathOp {
  const CubicTo(this.x1, this.y1, this.x2, this.y2, this.x, this.y);
  final double x1, y1, x2, y2, x, y;
}

class ClosePath extends PathOp {
  const ClosePath();
}

/// One outline of a shape: filled, stroked or both.
class GeomPath {
  const GeomPath(this.ops, {this.fill = true, this.stroke = true});

  final List<PathOp> ops;
  final bool fill;
  final bool stroke;
}

/// A shape's outline as stored in the file: a preset ("ellipse",
/// "rightArrow") with its adjust values, or a freeform drawn in its own
/// coordinate space.
class PptxGeometry {
  const PptxGeometry.preset(this.preset, [this.adjust = const {}]) : custom = const [];
  const PptxGeometry.custom(this.custom)
      : preset = 'custom',
        adjust = const {};

  final String preset;
  final Map<String, double> adjust;
  final List<CustomPath> custom;

  bool get isRect => preset == 'rect' || _rectLike.contains(preset);

  /// Lines and connectors have no inside to fill.
  bool get isLine => preset == 'line' || preset.contains('Connector');

  static const _rectLike = {'flowChartProcess', 'snip1Rect', 'snip2SameRect', 'snip2DiagRect', 'snipRoundRect', 'frame', 'halfFrame', 'corner', 'plaque'};

  /// Reads `prstGeom` or `custGeom` from a shape's `spPr`. Null means none
  /// (a plain rectangle).
  static PptxGeometry? read(XmlElement? spPr) {
    final prst = spPr?.kid('prstGeom');
    if (prst != null) {
      final adjust = <String, double>{};
      for (final gd in prst.kid('avLst')?.kids('gd') ?? const <XmlElement>[]) {
        final m = RegExp(r'^val\s+(-?\d+)').firstMatch(gd.attr('fmla') ?? '');
        final name = gd.attr('name');
        if (m != null && name != null) adjust[name] = double.parse(m[1]!);
      }
      return PptxGeometry.preset(prst.attr('prst') ?? 'rect', adjust);
    }
    final cust = spPr?.kid('custGeom');
    if (cust == null) return null;
    final paths = <CustomPath>[];
    for (final p in cust.kid('pathLst')?.kids('path') ?? const <XmlElement>[]) {
      final w = _number(p.attr('w')) ?? 0;
      final h = _number(p.attr('h')) ?? 0;
      final ops = <(String, List<double>)>[];
      var ok = true;
      for (final step in p.childElements) {
        final values = <double>[];
        final name = step.name.local;
        if (name == 'arcTo') {
          for (final a in const ['wR', 'hR', 'stAng', 'swAng']) {
            final v = _number(step.attr(a));
            if (v == null) ok = false;
            values.add(v ?? 0);
          }
        } else {
          for (final pt in step.kids('pt')) {
            final x = _number(pt.attr('x'));
            final y = _number(pt.attr('y'));
            if (x == null || y == null) ok = false;
            values
              ..add(x ?? 0)
              ..add(y ?? 0);
          }
        }
        ops.add((name, values));
      }
      // Guides written as formulas are not worked out; leave such paths out.
      if (!ok) continue;
      paths.add(CustomPath(w, h, ops, fill: p.attr('fill') != 'none', stroke: p.attr('stroke') != '0' && p.attr('stroke') != 'false'));
    }
    return paths.isEmpty ? null : PptxGeometry.custom(paths);
  }

  /// The outline for a box [w] by [h] points.
  List<GeomPath> paths(double w, double h) {
    if (preset == 'custom') return [for (final c in custom) c.scaled(w, h)];
    return [_preset(w, h)];
  }

  double _adj(String name, double fallback) => adjust[name] ?? fallback;

  GeomPath _poly(List<(double, double)> points, {bool close = true}) => GeomPath([
        MoveTo(points.first.$1, points.first.$2),
        for (final p in points.skip(1)) LineTo(p.$1, p.$2),
        if (close) const ClosePath(),
      ]);

  GeomPath _preset(double w, double h) {
    final ss = math.min(w, h);
    switch (preset) {
      case 'bentConnector2':
        return GeomPath([const MoveTo(0, 0), LineTo(w, 0), LineTo(w, h)], fill: false);
      case 'bentConnector3' || 'bentConnector4' || 'bentConnector5':
        final x = w * _adj('adj1', 50000) / 100000;
        return GeomPath([const MoveTo(0, 0), LineTo(x, 0), LineTo(x, h), LineTo(w, h)], fill: false);
      case 'curvedConnector2' || 'curvedConnector3' || 'curvedConnector4' || 'curvedConnector5':
        final x = w * _adj('adj1', 50000) / 100000;
        return GeomPath([const MoveTo(0, 0), CubicTo(x, 0, x, h, w, h)], fill: false);
      case 'line' || 'straightConnector1':
        return GeomPath([const MoveTo(0, 0), LineTo(w, h)], fill: false);
      case 'roundRect' || 'round1Rect' || 'round2SameRect' || 'round2DiagRect' || 'flowChartAlternateProcess':
        final r = math.min(ss * _adj('adj', 16667) / 100000, ss / 2);
        return GeomPath(_roundRect(w, h, r));
      case 'flowChartTerminator':
        return GeomPath(_roundRect(w, h, ss / 2));
      case 'ellipse' || 'flowChartConnector' || 'donut' || 'pie' || 'chord' || 'flowChartOr' || 'flowChartSummingJunction' || 'smileyFace':
        return GeomPath(_ellipse(0, 0, w, h));
      case 'triangle' || 'flowChartExtract':
        return _poly([(w * _adj('adj', 50000) / 100000, 0), (w, h), (0, h)]);
      case 'flowChartMerge':
        return _poly([(0, 0), (w, 0), (w / 2, h)]);
      case 'rtTriangle':
        return _poly([(0, 0), (w, h), (0, h)]);
      case 'diamond' || 'flowChartDecision':
        return _poly([(w / 2, 0), (w, h / 2), (w / 2, h), (0, h / 2)]);
      case 'parallelogram' || 'flowChartInputOutput':
        final x = math.min(ss * _adj('adj', 25000) / 100000, w);
        return _poly([(x, 0), (w, 0), (w - x, h), (0, h)]);
      case 'trapezoid' || 'flowChartManualOperation':
        final x = math.min(ss * _adj('adj', 25000) / 100000, w / 2);
        return _poly([(x, 0), (w - x, 0), (w, h), (0, h)]);
      case 'pentagon':
        return _poly([(w / 2, 0), (w, h * 0.38), (w * 0.81, h), (w * 0.19, h), (0, h * 0.38)]);
      case 'homePlate':
        final x = w - math.min(ss * _adj('adj', 50000) / 100000, w);
        return _poly([(0, 0), (x, 0), (w, h / 2), (x, h), (0, h)]);
      case 'chevron':
        final x = math.min(ss * _adj('adj', 50000) / 100000, w);
        return _poly([(0, 0), (w - x, 0), (w, h / 2), (w - x, h), (0, h), (x, h / 2)]);
      case 'hexagon':
        final x = math.min(ss * _adj('adj', 25000) / 100000, w / 2);
        return _poly([(x, 0), (w - x, 0), (w, h / 2), (w - x, h), (x, h), (0, h / 2)]);
      case 'octagon':
        final x = math.min(ss * _adj('adj', 29289) / 100000, ss / 2);
        return _poly([(x, 0), (w - x, 0), (w, x), (w, h - x), (w - x, h), (x, h), (0, h - x), (0, x)]);
      case 'plus':
        final x = math.min(ss * _adj('adj', 25000) / 100000, ss / 2);
        return _poly([(x, 0), (w - x, 0), (w - x, x), (w, x), (w, h - x), (w - x, h - x), (w - x, h), (x, h), (x, h - x), (0, h - x), (0, x), (x, x)]);
      case 'rightArrow' || 'leftArrow':
        final shaft = h * _adj('adj1', 50000) / 100000;
        final head = math.min(ss * _adj('adj2', 50000) / 100000, w);
        final top = (h - shaft) / 2;
        final pts = [(0.0, top), (w - head, top), (w - head, 0.0), (w, h / 2), (w - head, h), (w - head, top + shaft), (0.0, top + shaft)];
        return _poly(preset == 'rightArrow' ? pts : [for (final p in pts) (w - p.$1, p.$2)]);
      case 'downArrow' || 'upArrow':
        final shaft = w * _adj('adj1', 50000) / 100000;
        final head = math.min(ss * _adj('adj2', 50000) / 100000, h);
        final left = (w - shaft) / 2;
        final pts = [(left, 0.0), (left + shaft, 0.0), (left + shaft, h - head), (w, h - head), (w / 2, h), (0.0, h - head), (left, h - head)];
        return _poly(preset == 'downArrow' ? pts : [for (final p in pts) (p.$1, h - p.$2)]);
      case 'star4' || 'star5' || 'star6' || 'star8' || 'star10' || 'star12':
        final n = int.parse(preset.substring(4));
        final inner = (_adj('adj', n == 5 ? 19098 : 37500) / 50000).clamp(0.05, 1.0);
        final pts = <(double, double)>[];
        for (var i = 0; i < n * 2; i++) {
          final a = -math.pi / 2 + i * math.pi / n;
          final r = i.isEven ? 1.0 : inner;
          pts.add((w / 2 + w / 2 * r * math.cos(a), h / 2 + h / 2 * r * math.sin(a)));
        }
        return _poly(pts);
      default:
        return _poly([(0, 0), (w, 0), (w, h), (0, h)]);
    }
  }

  static const _k = 0.5522847498;

  static List<PathOp> _ellipse(double x, double y, double w, double h) {
    final rx = w / 2, ry = h / 2, cx = x + rx, cy = y + ry;
    return [
      MoveTo(cx + rx, cy),
      CubicTo(cx + rx, cy + ry * _k, cx + rx * _k, cy + ry, cx, cy + ry),
      CubicTo(cx - rx * _k, cy + ry, cx - rx, cy + ry * _k, cx - rx, cy),
      CubicTo(cx - rx, cy - ry * _k, cx - rx * _k, cy - ry, cx, cy - ry),
      CubicTo(cx + rx * _k, cy - ry, cx + rx, cy - ry * _k, cx + rx, cy),
      const ClosePath(),
    ];
  }

  static List<PathOp> _roundRect(double w, double h, double r) {
    if (r <= 0) return [const MoveTo(0, 0), LineTo(w, 0), LineTo(w, h), LineTo(0, h), const ClosePath()];
    final c = r * (1 - _k);
    return [
      MoveTo(r, 0),
      LineTo(w - r, 0),
      CubicTo(w - c, 0, w, c, w, r),
      LineTo(w, h - r),
      CubicTo(w, h - c, w - c, h, w - r, h),
      LineTo(r, h),
      CubicTo(c, h, 0, h - c, 0, h - r),
      LineTo(0, r),
      CubicTo(0, c, c, 0, r, 0),
      const ClosePath(),
    ];
  }
}

/// A freeform path in its own coordinates ([w] by [h]).
class CustomPath {
  const CustomPath(this.w, this.h, this.ops, {this.fill = true, this.stroke = true});

  final double w;
  final double h;
  final List<(String, List<double>)> ops;
  final bool fill;
  final bool stroke;

  GeomPath scaled(double width, double height) {
    final sx = w == 0 ? 1.0 : width / w;
    final sy = h == 0 ? 1.0 : height / h;
    final out = <PathOp>[];
    var cx = 0.0, cy = 0.0;
    for (final (name, v) in ops) {
      switch (name) {
        case 'moveTo' when v.length >= 2:
          cx = v[0] * sx;
          cy = v[1] * sy;
          out.add(MoveTo(cx, cy));
        case 'lnTo' when v.length >= 2:
          cx = v[0] * sx;
          cy = v[1] * sy;
          out.add(LineTo(cx, cy));
        case 'cubicBezTo' when v.length >= 6:
          cx = v[4] * sx;
          cy = v[5] * sy;
          out.add(CubicTo(v[0] * sx, v[1] * sy, v[2] * sx, v[3] * sy, cx, cy));
        case 'quadBezTo' when v.length >= 4:
          final qx = v[0] * sx, qy = v[1] * sy, ex = v[2] * sx, ey = v[3] * sy;
          out.add(CubicTo(cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy), ex + 2 / 3 * (qx - ex), ey + 2 / 3 * (qy - ey), ex, ey));
          cx = ex;
          cy = ey;
        case 'arcTo' when v.length >= 4:
          // The arc starts at the current point, on an ellipse with radii
          // wR, hR, at angle stAng, and sweeps swAng (60000ths of a degree).
          final rx = v[0] * sx, ry = v[1] * sy;
          final start = v[2] / 60000 * math.pi / 180;
          // At most one full turn.
          final sweep = v[3].clamp(-21600000, 21600000) / 60000 * math.pi / 180;
          if (rx == 0 || ry == 0 || sweep == 0) break;
          final ox = cx - rx * math.cos(start), oy = cy - ry * math.sin(start);
          final pieces = math.max(1, (sweep.abs() / (math.pi / 2)).ceil());
          final step = sweep / pieces;
          var a = start;
          for (var i = 0; i < pieces; i++) {
            final b = a + step;
            final t = 4 / 3 * math.tan(step / 4);
            final x1 = ox + rx * (math.cos(a) - t * math.sin(a)), y1 = oy + ry * (math.sin(a) + t * math.cos(a));
            final x2 = ox + rx * (math.cos(b) + t * math.sin(b)), y2 = oy + ry * (math.sin(b) - t * math.cos(b));
            cx = ox + rx * math.cos(b);
            cy = oy + ry * math.sin(b);
            out.add(CubicTo(x1, y1, x2, y2, cx, cy));
            a = b;
          }
        case 'close':
          out.add(const ClosePath());
      }
    }
    return GeomPath(out, fill: fill, stroke: stroke);
  }
}

/// A whole number from a shape's outline, or null. The format only allows
/// integers, which also keeps out NaN, Infinity and runaway sizes.
double? _number(String? text) {
  final v = int.tryParse(text?.trim() ?? '');
  return v == null || v.abs() > 1 << 40 ? null : v.toDouble();
}
