import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show Matrix4;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../ooxml/pptx_geometry.dart';
import '../ooxml/pptx_reader.dart';

const _emuPerPt = 12700.0;

PdfColor pdfColor(PptxColor c) => PdfColor.fromInt(0xFF000000 | (int.tryParse(c.hex, radix: 16) ?? 0));

/// Pictures for one PDF, each embedded once however many slides use it, with
/// PowerPoint's recolouring (two-tone, greyscale, washout) and tiling baked in.
class PptxPdfImages {
  final _cache = <(Uint8List, String), pw.ImageProvider?>{};

  /// The picture of [fill] ready to stretch over a box of [width] x [height]
  /// points, or null when it cannot be decoded.
  pw.ImageProvider? of(PptxFill fill, double width, double height) {
    final bytes = fill.image;
    if (bytes == null) return null;
    final matrix = fill.colorMatrix;
    // Tiles keep the picture's own size, so the box size matters for them.
    final tileKey = fill.tile ? '${width.round()}x${height.round()}' : '';
    final key = (bytes, '${matrix?.join(',')}|$tileKey');
    if (_cache.containsKey(key)) return _cache[key];
    pw.ImageProvider? result;
    try {
      if (matrix == null && !fill.tile) {
        result = pw.MemoryImage(bytes);
      } else {
        result = _processed(bytes, matrix, fill.tile ? (width, height) : null);
      }
    } catch (_) {
      result = null;
    }
    _cache[key] = result;
    return result;
  }

  static pw.ImageProvider? _processed(Uint8List bytes, List<double>? matrix, (double, double)? tileBox) {
    // Very large pictures are kept as they are rather than decoded in memory.
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null || info.width * info.height > 40 * 1000 * 1000) return pw.MemoryImage(bytes);
    var image = img.decodeImage(bytes);
    if (image == null) return null;
    // Keep work and file size bounded on big photos.
    const maxEdge = 2000;
    if (math.max(image.width, image.height) > maxEdge && tileBox == null) {
      image = image.width >= image.height ? img.copyResize(image, width: maxEdge) : img.copyResize(image, height: maxEdge);
    }
    if (tileBox != null) image = _tiled(image, tileBox.$1, tileBox.$2);
    final seeThrough = matrix != null && !(matrix[15] == 0 && matrix[16] == 0 && matrix[17] == 0 && matrix[18] == 1 && matrix[19] == 0);
    if (matrix != null) {
      if (image.hasPalette) image = image.convert(numChannels: image.numChannels);
      // Grey pictures need colour channels to take on the new colours.
      if (image.numChannels < 3 || (seeThrough && image.numChannels < 4)) {
        image = image.convert(numChannels: seeThrough || image.numChannels == 2 || image.numChannels == 4 ? 4 : 3);
      }
      final m = matrix;
      for (final p in image) {
        final r = p.rNormalized * 255, g = p.gNormalized * 255, b = p.bNormalized * 255, a = p.aNormalized * 255;
        double ch(int row) => (m[row * 5] * r + m[row * 5 + 1] * g + m[row * 5 + 2] * b + m[row * 5 + 3] * a + m[row * 5 + 4]).clamp(0, 255) / 255;
        final nr = ch(0), ng = ch(1), nb = ch(2), na = ch(3);
        p
          ..rNormalized = nr
          ..gNormalized = ng
          ..bNormalized = nb;
        if (image.numChannels == 4) p.aNormalized = na;
      }
    }
    final keepAlpha = image.numChannels == 4;
    return pw.MemoryImage(keepAlpha ? img.encodePng(image) : img.encodeJpg(image, quality: 90));
  }

  /// Repeats [tile] at its own size (96 pixels to the inch) over the box.
  static img.Image _tiled(img.Image tile, double width, double height) {
    var w = math.max(1, (width / 0.75).round());
    var h = math.max(1, (height / 0.75).round());
    var tw = tile.width, th = tile.height;
    const maxEdge = 2000;
    final shrink = math.max(w, h) / maxEdge;
    if (shrink > 1) {
      w = (w / shrink).round().clamp(1, maxEdge);
      h = (h / shrink).round().clamp(1, maxEdge);
      tw = math.max(1, (tw / shrink).round());
      th = math.max(1, (th / shrink).round());
      tile = img.copyResize(tile, width: tw, height: th);
    }
    if (tile.hasPalette) tile = tile.convert(numChannels: tile.numChannels);
    final out = img.Image(width: w, height: h, numChannels: tile.numChannels);
    for (var y = 0; y < h; y += th) {
      for (var x = 0; x < w; x += tw) {
        img.compositeImage(out, tile, dstX: x, dstY: y, blend: img.BlendMode.direct);
      }
    }
    return out;
  }
}

/// A PowerPoint shape's fill and outline in a PDF: solid, gradient or
/// picture, clipped to the shape's outline (ellipse, arrow, star...).
class PptxPdfShape extends pw.Widget {
  PptxPdfShape({
    required this.width,
    required this.height,
    required this.images,
    this.fill,
    this.line,
    this.geometry,
    this.flipH = false,
    this.flipV = false,
  });

  final double width;
  final double height;
  final PptxPdfImages images;
  final PptxFill? fill;
  final PptxLine? line;
  final PptxGeometry? geometry;
  final bool flipH;
  final bool flipV;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    box = PdfRect.fromPoints(PdfPoint.zero, constraints.constrain(PdfPoint(width, height)));
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final b = box!;
    final canvas = context.canvas;
    final g = geometry;
    final isLine = g?.isLine ?? false;
    final f = fill;
    if (f != null && !isLine) {
      final image = f.image == null ? null : images.of(f, b.width, b.height);
      if (f.color != null) {
        canvas.saveContext();
        _opacity(context, f.color!.alpha);
        canvas.setFillColor(pdfColor(f.color!));
        _outline(canvas, b, forFill: true);
        canvas.fillPath();
        canvas.restoreContext();
      } else if (f.stops.length >= 2) {
        canvas.saveContext();
        if (f.stops.any((s) => s.color.alpha < 1)) {
          // See-through stops: a grey copy of the gradient masks the colours.
          // (The mask writes its box as two corners, so pass the far corner as the size.)
          final mask = PdfSoftMask(context.document, boundingBox: PdfRect(math.min(0, b.left), math.min(0, b.bottom), b.right, b.top));
          final maskCanvas = mask.getGraphics()!..drawRect(b.left, b.bottom, b.width, b.height);
          _gradient(f, alphaOnly: true).paint(context.copyWith(canvas: maskCanvas), b);
          canvas.setGraphicState(PdfGraphicState(softMask: mask));
        }
        _outline(canvas, b, forFill: true);
        _gradient(f).paint(context, b);
        canvas.restoreContext();
      } else if (image != null) {
        canvas.saveContext();
        _outline(canvas, b, forFill: true);
        canvas.clipPath();
        if (flipH || flipV) {
          // Mirror the picture itself; the outline above is already mirrored.
          final cx = b.left + b.width / 2, cy = b.bottom + b.height / 2;
          canvas.setTransform(Matrix4.translationValues(cx, cy, 0)
            ..scaleByDouble(flipH ? -1 : 1, flipV ? -1 : 1, 1, 1)
            ..translateByDouble(-cx, -cy, 0, 1));
        }
        pw.DecorationImage(image: image, fit: pw.BoxFit.fill).paint(context, b);
        canvas.restoreContext();
      }
    }
    final l = line;
    if (l != null) {
      canvas.saveContext();
      _opacity(context, l.color.alpha);
      canvas
        ..setStrokeColor(pdfColor(l.color))
        ..setFillColor(pdfColor(l.color))
        ..setLineWidth(math.max(0.25, l.widthEmu / _emuPerPt));
      _outline(canvas, b, forFill: false);
      canvas.strokePath();
      if (isLine && (l.arrowAtStart || l.arrowAtEnd)) _arrowheads(canvas, b, math.max(0.25, l.widthEmu / _emuPerPt), l);
      canvas.restoreContext();
    }
  }

  void _opacity(pw.Context context, double alpha) {
    if (alpha < 1) context.canvas.setGraphicState(PdfGraphicState(opacity: alpha.clamp(0, 1)));
  }

  pw.Gradient _gradient(PptxFill f, {bool alphaOnly = false}) {
    final colors = [
      for (final s in f.stops) alphaOnly ? PdfColor(s.color.alpha.clamp(0, 1), s.color.alpha.clamp(0, 1), s.color.alpha.clamp(0, 1)) : pdfColor(s.color),
    ];
    final stops = [for (final s in f.stops) s.position.clamp(0.0, 1.0)];
    if (f.radial) {
      return pw.RadialGradient(center: pw.Alignment(f.centerX * 2 - 1, 1 - f.centerY * 2), radius: 0.75, colors: colors, stops: stops);
    }
    final a = f.angle * math.pi / 180;
    final dx = math.cos(a), dy = math.sin(a);
    final k = 1 / math.max(dx.abs(), dy.abs());
    // PDF's y axis points up, PowerPoint's down.
    return pw.LinearGradient(begin: pw.Alignment(-dx * k, dy * k), end: pw.Alignment(dx * k, -dy * k), colors: colors, stops: stops);
  }

  /// Points of the shape in PDF space, flipped as PowerPoint asks.
  (double, double) Function(double, double) _mapper(PdfRect b) =>
      (x, y) => (b.left + (flipH ? b.width - x : x), b.bottom + b.height - (flipV ? b.height - y : y));

  void _outline(PdfGraphics canvas, PdfRect b, {required bool forFill}) {
    final g = geometry;
    if (g == null || (g.isRect && !g.isLine)) {
      canvas.drawRect(b.left, b.bottom, b.width, b.height);
      return;
    }
    final map = _mapper(b);
    for (final gp in g.paths(b.width, b.height)) {
      if (forFill ? !gp.fill : !gp.stroke) continue;
      for (final op in gp.ops) {
        switch (op) {
          case MoveTo(:final x, :final y):
            final p = map(x, y);
            canvas.moveTo(p.$1, p.$2);
          case LineTo(:final x, :final y):
            final p = map(x, y);
            canvas.lineTo(p.$1, p.$2);
          case CubicTo(:final x1, :final y1, :final x2, :final y2, :final x, :final y):
            final p1 = map(x1, y1), p2 = map(x2, y2), p = map(x, y);
            canvas.curveTo(p1.$1, p1.$2, p2.$1, p2.$2, p.$1, p.$2);
          case ClosePath():
            canvas.closePath();
        }
      }
    }
  }

  /// Triangles at the ends of a line, pointing along its first and last parts.
  void _arrowheads(PdfGraphics canvas, PdfRect b, double lineWidth, PptxLine l) {
    final map = _mapper(b);
    final pts = <(double, double)>[];
    for (final gp in geometry!.paths(b.width, b.height)) {
      for (final op in gp.ops) {
        switch (op) {
          case MoveTo(:final x, :final y) || LineTo(:final x, :final y):
            pts.add(map(x, y));
          case CubicTo(:final x1, :final y1, :final x2, :final y2, :final x, :final y):
            pts.addAll([map(x1, y1), map(x2, y2), map(x, y)]);
          case ClosePath():
        }
      }
    }
    if (pts.length < 2) return;
    final len = math.max(4.5, lineWidth * 3.5);
    void head((double, double) tip, (double, double) from) {
      final dx = tip.$1 - from.$1, dy = tip.$2 - from.$2;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d == 0) return;
      final ux = dx / d, uy = dy / d, nx = -uy, ny = ux;
      canvas
        ..moveTo(tip.$1, tip.$2)
        ..lineTo(tip.$1 - ux * len + nx * len / 2, tip.$2 - uy * len + ny * len / 2)
        ..lineTo(tip.$1 - ux * len - nx * len / 2, tip.$2 - uy * len - ny * len / 2)
        ..closePath()
        ..fillPath();
    }

    if (l.arrowAtStart) head(pts.first, pts.firstWhere((p) => p != pts.first, orElse: () => pts.first));
    if (l.arrowAtEnd) head(pts.last, pts.lastWhere((p) => p != pts.last, orElse: () => pts.last));
  }
}
