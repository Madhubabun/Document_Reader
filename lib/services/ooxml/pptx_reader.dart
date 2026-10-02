import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'xml_utils.dart';

class PptxRun {
  const PptxRun(this.text, {this.bold = false, this.italic = false, this.fontSizePt, this.color});

  final String text;
  final bool bold;
  final bool italic;
  final double? fontSizePt;
  final String? color;
}

class PptxParagraph {
  const PptxParagraph(this.runs, {this.level = 0, this.bullet = false, this.align = 'l'});

  final List<PptxRun> runs;
  final int level;
  final bool bullet;

  /// DrawingML alignment: l, ctr, r, just.
  final String align;

  String get text => runs.map((r) => r.text).join();
}

enum PptxShapeKind { title, body, text, picture }

/// A rectangle in EMU (914400 per inch) relative to the slide's top-left.
class EmuRect {
  const EmuRect(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;
}

class PptxShape {
  const PptxShape({required this.kind, this.rect, this.paragraphs = const [], this.imageBytes, this.fill});

  final PptxShapeKind kind;
  final EmuRect? rect;
  final List<PptxParagraph> paragraphs;
  final Uint8List? imageBytes;
  final String? fill;

  String get text => paragraphs.map((p) => p.text).join('\n');
}

class PptxSlide {
  const PptxSlide(this.shapes, {this.background});

  final List<PptxShape> shapes;
  final String? background;

  String? get title {
    for (final s in shapes) {
      if (s.kind == PptxShapeKind.title && s.text.trim().isNotEmpty) return s.text.trim();
    }
    return null;
  }
}

class PptxPresentation {
  const PptxPresentation({required this.slideWidth, required this.slideHeight, required this.slides});

  final int slideWidth;
  final int slideHeight;
  final List<PptxSlide> slides;

  double get aspectRatio => slideHeight == 0 ? 16 / 9 : slideWidth / slideHeight;
}

/// Reads slides, text boxes and pictures from a .pptx (PresentationML) file.
class PptxReader {
  static const defaultWidth = 12192000; // 13.333 in, 16:9
  static const defaultHeight = 6858000; // 7.5 in

  static PptxPresentation read(List<int> bytes) {
    final pkg = OoxmlPackage(bytes);
    const presPart = 'ppt/presentation.xml';
    final pres = pkg.xml(presPart);
    if (pres == null) throw OoxmlFormatException('Not a PowerPoint file (ppt/presentation.xml missing).');
    final size = pres.rootElement.kid('sldSz');
    final width = int.tryParse(size?.attr('cx') ?? '') ?? defaultWidth;
    final height = int.tryParse(size?.attr('cy') ?? '') ?? defaultHeight;

    final rels = pkg.relationships(presPart);
    final slides = <PptxSlide>[];
    for (final id in pres.rootElement.kid('sldIdLst')?.kids('sldId') ?? const <Never>[]) {
      final target = rels[id.relId];
      if (target == null) continue;
      final slideXml = pkg.xml(target);
      if (slideXml == null) continue;
      slides.add(_readSlide(pkg, target, slideXml));
    }
    return PptxPresentation(slideWidth: width, slideHeight: height, slides: slides);
  }

  static PptxSlide _readSlide(OoxmlPackage pkg, String part, XmlDocument xml) {
    final rels = pkg.relationships(part);
    final cSld = xml.rootElement.kid('cSld');
    final tree = cSld?.kid('spTree');
    final shapes = <PptxShape>[];
    // Placeholders often have no position of their own: they inherit it from
    // the slide layout, which in turn inherits from the slide master.
    final layoutPart = pkg.relationshipOfType(part, '/slideLayout');
    final masterPart = layoutPart == null ? null : pkg.relationshipOfType(layoutPart, '/slideMaster');
    final inherited = [
      if (layoutPart != null) _placeholderRects(pkg.xml(layoutPart)),
      if (masterPart != null) _placeholderRects(pkg.xml(masterPart)),
    ];
    if (tree != null) _collect(pkg, rels, tree, shapes, inherited);
    final bg = cSld?.kid('bg')?.deep('srgbClr').firstOrNull?.attr('val');
    return PptxSlide(shapes, background: bg);
  }

  /// Placeholder key -> rectangle, keyed both by `idx:N` and by `type:T`.
  static Map<String, EmuRect> _placeholderRects(XmlDocument? xml) {
    final result = <String, EmuRect>{};
    final tree = xml?.rootElement.kid('cSld')?.kid('spTree');
    for (final sp in tree?.deep('sp') ?? const <XmlElement>[]) {
      final ph = sp.kid('nvSpPr')?.kid('nvPr')?.kid('ph');
      final rect = _rect(sp.kid('spPr'));
      if (ph == null || rect == null) continue;
      final idx = ph.attr('idx');
      if (idx != null) result.putIfAbsent('idx:$idx', () => rect);
      result.putIfAbsent('type:${_normalType(ph.attr('type'))}', () => rect);
    }
    return result;
  }

  static String _normalType(String? type) => switch (type) {
        null || 'obj' => 'body',
        'ctrTitle' => 'title',
        _ => type,
      };

  static EmuRect? _inheritedRect(XmlElement? ph, List<Map<String, EmuRect>> inherited) {
    if (ph == null) return null;
    final idx = ph.attr('idx');
    final type = _normalType(ph.attr('type'));
    for (final map in inherited) {
      final hit = (idx == null ? null : map['idx:$idx']) ?? map['type:$type'];
      if (hit != null) return hit;
    }
    // A subtitle or centered title on a master is usually stored as body/title.
    for (final map in inherited) {
      final hit = map[type == 'subTitle' ? 'type:body' : 'type:$type'];
      if (hit != null) return hit;
    }
    return null;
  }

  static void _collect(OoxmlPackage pkg, Map<String, String> rels, XmlElement tree, List<PptxShape> out, List<Map<String, EmuRect>> inherited) {
    for (final el in tree.childElements) {
      switch (el.name.local) {
        case 'sp':
          final ph = el.kid('nvSpPr')?.kid('nvPr')?.kid('ph');
          final phType = ph?.attr('type');
          final kind = switch (phType) {
            'title' || 'ctrTitle' => PptxShapeKind.title,
            _ when ph != null => PptxShapeKind.body,
            _ => PptxShapeKind.text,
          };
          final paragraphs = <PptxParagraph>[];
          for (final p in el.kid('txBody')?.kids('p') ?? const <Never>[]) {
            paragraphs.add(_paragraph(p, inBody: kind == PptxShapeKind.body && phType != 'subTitle'));
          }
          final spPr = el.kid('spPr');
          final fill = spPr?.kid('solidFill')?.kid('srgbClr')?.attr('val');
          if (paragraphs.every((p) => p.text.trim().isEmpty) && fill == null) continue;
          out.add(PptxShape(kind: kind, rect: _rect(spPr) ?? _inheritedRect(ph, inherited), paragraphs: paragraphs, fill: fill));
        case 'pic':
          final id = el.deep('blip').firstOrNull?.attr('embed');
          final target = id == null ? null : rels[id];
          final data = target == null ? null : pkg.bytes(target);
          if (data == null) continue;
          out.add(PptxShape(
            kind: PptxShapeKind.picture,
            rect: _rect(el.kid('spPr')),
            imageBytes: Uint8List.fromList(data),
          ));
        case 'grpSp':
          _collect(pkg, rels, el, out, inherited);
      }
    }
  }

  static PptxParagraph _paragraph(XmlElement p, {required bool inBody}) {
    final pPr = p.kid('pPr');
    final runs = <PptxRun>[];
    for (final child in p.childElements) {
      if (child.name.local == 'br') {
        runs.add(const PptxRun('\n'));
        continue;
      }
      if (child.name.local != 'r' && child.name.local != 'fld') continue;
      final t = child.kid('t')?.innerText ?? '';
      if (t.isEmpty) continue;
      final rPr = child.kid('rPr');
      final sz = int.tryParse(rPr?.attr('sz') ?? '');
      runs.add(PptxRun(
        t,
        bold: rPr?.attr('b') == '1' || rPr?.attr('b') == 'true',
        italic: rPr?.attr('i') == '1' || rPr?.attr('i') == 'true',
        fontSizePt: sz == null ? null : sz / 100,
        color: rPr?.kid('solidFill')?.kid('srgbClr')?.attr('val'),
      ));
    }
    final noBullet = pPr?.kid('buNone') != null;
    final explicitBullet = pPr?.kid('buChar') != null || pPr?.kid('buAutoNum') != null;
    return PptxParagraph(
      runs,
      level: int.tryParse(pPr?.attr('lvl') ?? '') ?? 0,
      bullet: explicitBullet || (inBody && !noBullet),
      align: pPr?.attr('algn') ?? 'l',
    );
  }

  static EmuRect? _rect(XmlElement? spPr) {
    final xfrm = spPr?.kid('xfrm');
    final off = xfrm?.kid('off');
    final ext = xfrm?.kid('ext');
    if (off == null || ext == null) return null;
    return EmuRect(
      int.tryParse(off.attr('x') ?? '') ?? 0,
      int.tryParse(off.attr('y') ?? '') ?? 0,
      int.tryParse(ext.attr('cx') ?? '') ?? 0,
      int.tryParse(ext.attr('cy') ?? '') ?? 0,
    );
  }
}
