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
  const PptxShape({required this.kind, this.rect, this.paragraphs = const [], this.imageBytes, this.fill, this.anchor = 't'});

  final PptxShapeKind kind;
  final EmuRect? rect;
  final List<PptxParagraph> paragraphs;
  final Uint8List? imageBytes;
  final String? fill;

  /// Vertical text anchor inside the box: t, ctr or b.
  final String anchor;

  String get text => paragraphs.map((p) => p.text).join('\n');
}

class PptxSlide {
  const PptxSlide(this.shapes, {this.background, this.backgroundImage});

  final List<PptxShape> shapes;

  /// Solid background colour (RGB hex), from the slide, its layout or master.
  final String? background;

  /// Picture background, drawn stretched over the whole slide.
  final Uint8List? backgroundImage;

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
      slides.add(_readSlide(pkg, target, slideXml, pres.rootElement.kid('defaultTextStyle')));
    }
    return PptxPresentation(slideWidth: width, slideHeight: height, slides: slides);
  }

  static PptxSlide _readSlide(OoxmlPackage pkg, String part, XmlDocument xml, XmlElement? defaultTextStyle) {
    final rels = pkg.relationships(part);
    final cSld = xml.rootElement.kid('cSld');
    final tree = cSld?.kid('spTree');
    final shapes = <PptxShape>[];
    // Placeholders often have no position or text style of their own: they
    // inherit them from the slide layout, which inherits from the master.
    final layoutPart = pkg.relationshipOfType(part, '/slideLayout');
    final masterPart = layoutPart == null ? null : pkg.relationshipOfType(layoutPart, '/slideMaster');
    final layout = layoutPart == null ? null : pkg.xml(layoutPart);
    final master = masterPart == null ? null : pkg.xml(masterPart);
    final themePart = masterPart == null ? null : pkg.relationshipOfType(masterPart, '/theme');
    final colors = SchemeColors.from(themePart == null ? null : pkg.xml(themePart), master?.rootElement.kid('clrMap'));
    final txStyles = master?.rootElement.kid('txStyles');
    final ctx = _SlideContext(
      colors: colors,
      inherited: [
        if (layout != null) _placeholders(layout),
        if (master != null) _placeholders(master),
      ],
      titleStyle: _levels(txStyles?.kid('titleStyle')),
      bodyStyle: _levels(txStyles?.kid('bodyStyle')),
      otherStyle: _levels(defaultTextStyle ?? txStyles?.kid('otherStyle')),
    );
    if (tree != null) _collect(pkg, rels, tree, shapes, ctx);

    // Background: the first of slide, layout and master that defines one.
    String? bgColor;
    Uint8List? bgImage;
    for (final (owner, ownerPart) in [(xml, part), (layout, layoutPart), (master, masterPart)]) {
      final bg = owner?.rootElement.kid('cSld')?.kid('bg');
      if (bg == null || ownerPart == null) continue;
      final bgPr = bg.kid('bgPr');
      if (bgPr != null) {
        final blip = bgPr.kid('blipFill')?.kid('blip')?.attr('embed');
        if (blip != null) {
          final target = pkg.relationships(ownerPart)[blip];
          final data = target == null ? null : pkg.bytes(target);
          if (data != null) bgImage = Uint8List.fromList(data);
        }
        bgColor = colors.fill(bgPr);
      } else {
        bgColor = colors.resolve(bg.kid('bgRef'));
      }
      break;
    }
    return PptxSlide(shapes, background: bgColor, backgroundImage: bgImage);
  }

  /// Placeholder key -> position and text style, keyed both by `idx:N` and by `type:T`.
  static Map<String, _Placeholder> _placeholders(XmlDocument xml) {
    final result = <String, _Placeholder>{};
    final tree = xml.rootElement.kid('cSld')?.kid('spTree');
    for (final sp in tree?.deep('sp') ?? const <XmlElement>[]) {
      final ph = sp.kid('nvSpPr')?.kid('nvPr')?.kid('ph');
      if (ph == null) continue;
      final info = _Placeholder(_rect(sp.kid('spPr')), _levels(sp.kid('txBody')?.kid('lstStyle')), sp.kid('txBody')?.kid('bodyPr')?.attr('anchor'));
      final idx = ph.attr('idx');
      if (idx != null) result.putIfAbsent('idx:$idx', () => info);
      result.putIfAbsent('type:${_normalType(ph.attr('type'))}', () => info);
    }
    return result;
  }

  static String _normalType(String? type) => switch (type) {
        null || 'obj' => 'body',
        'ctrTitle' => 'title',
        _ => type,
      };

  /// Placeholders this one inherits from, nearest (layout) first.
  static List<_Placeholder> _inheritedFrom(XmlElement? ph, List<Map<String, _Placeholder>> inherited) {
    if (ph == null) return const [];
    final idx = ph.attr('idx');
    final type = _normalType(ph.attr('type'));
    final out = <_Placeholder>[];
    for (final map in inherited) {
      // A subtitle on a master is usually stored as the body placeholder.
      final hit = (idx == null ? null : map['idx:$idx']) ?? map['type:$type'] ?? (type == 'subTitle' ? map['type:body'] : null);
      if (hit != null) out.add(hit);
    }
    return out;
  }

  static void _collect(OoxmlPackage pkg, Map<String, String> rels, XmlElement tree, List<PptxShape> out, _SlideContext ctx) {
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
          final parents = _inheritedFrom(ph, ctx.inherited);
          final base = switch (kind) {
            PptxShapeKind.title => ctx.titleStyle,
            PptxShapeKind.body => ctx.bodyStyle,
            _ => ctx.otherStyle,
          };
          final txBody = el.kid('txBody');
          final chain = [
            _levels(txBody?.kid('lstStyle')),
            for (final parent in parents) parent.levels,
            base,
          ];
          // Shapes drawn with a theme style carry their default text colour here.
          final styleColor = ctx.colors.resolve(el.kid('style')?.kid('fontRef'));
          final paragraphs = <PptxParagraph>[];
          for (final p in txBody?.kids('p') ?? const <Never>[]) {
            paragraphs.add(_paragraph(p, chain, ctx.colors, styleColor, bulletByDefault: kind == PptxShapeKind.body && phType != 'subTitle'));
          }
          final spPr = el.kid('spPr');
          final fill = ctx.colors.fill(spPr);
          if (paragraphs.every((p) => p.text.trim().isEmpty) && fill == null) continue;
          var rect = _rect(spPr);
          var anchor = txBody?.kid('bodyPr')?.attr('anchor');
          for (final parent in parents) {
            rect ??= parent.rect;
            anchor ??= parent.anchor;
          }
          out.add(PptxShape(kind: kind, rect: rect, paragraphs: paragraphs, fill: fill, anchor: anchor ?? 't'));
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
          _collect(pkg, rels, el, out, ctx);
      }
    }
  }

  static PptxParagraph _paragraph(XmlElement p, List<Map<int, _Level>> chain, SchemeColors colors, String? styleColor,
      {required bool bulletByDefault}) {
    final pPr = p.kid('pPr');
    final level = (int.tryParse(pPr?.attr('lvl') ?? '') ?? 0).clamp(0, 8);
    T? inherited<T>(T? Function(_Level l) pick) {
      for (final levels in chain) {
        final l = levels[level];
        final v = l == null ? null : pick(l);
        if (v != null) return v;
      }
      return null;
    }

    final defaultSize = inherited((l) => l.size);
    final defaultBold = inherited((l) => l.bold) ?? false;
    final defaultColor = inherited((l) => colors.resolve(l.fill)) ?? styleColor;
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
      final b = rPr?.attr('b');
      runs.add(PptxRun(
        t,
        bold: b == null ? defaultBold : (b == '1' || b == 'true'),
        italic: rPr?.attr('i') == '1' || rPr?.attr('i') == 'true',
        fontSizePt: sz != null ? sz / 100 : defaultSize,
        color: colors.resolve(rPr?.kid('solidFill')) ?? defaultColor,
      ));
    }
    bool? bullet;
    if (pPr?.kid('buNone') != null) {
      bullet = false;
    } else if (pPr?.kid('buChar') != null || pPr?.kid('buAutoNum') != null) {
      bullet = true;
    }
    bullet ??= inherited((l) => l.bullet) ?? bulletByDefault;
    return PptxParagraph(
      runs,
      level: level,
      bullet: bullet,
      align: pPr?.attr('algn') ?? inherited((l) => l.align) ?? 'l',
    );
  }

  /// `lvl1pPr`..`lvl9pPr` of a list style, keyed by zero-based level.
  static Map<int, _Level> _levels(XmlElement? listStyle) {
    if (listStyle == null) return const {};
    final out = <int, _Level>{};
    for (var i = 0; i < 9; i++) {
      final pPr = listStyle.kid('lvl${i + 1}pPr');
      if (pPr == null) continue;
      final rPr = pPr.kid('defRPr');
      final sz = int.tryParse(rPr?.attr('sz') ?? '');
      final b = rPr?.attr('b');
      out[i] = _Level(
        size: sz == null ? null : sz / 100,
        bold: b == null ? null : (b == '1' || b == 'true'),
        fill: rPr?.kid('solidFill'),
        bullet: pPr.kid('buNone') != null ? false : (pPr.kid('buChar') != null || pPr.kid('buAutoNum') != null ? true : null),
        align: pPr.attr('algn'),
      );
    }
    return out;
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

class _Placeholder {
  const _Placeholder(this.rect, this.levels, this.anchor);

  final EmuRect? rect;
  final Map<int, _Level> levels;
  final String? anchor;
}

class _Level {
  const _Level({this.size, this.bold, this.fill, this.bullet, this.align});

  final double? size;
  final bool? bold;
  final XmlElement? fill;
  final bool? bullet;
  final String? align;
}

class _SlideContext {
  const _SlideContext({required this.colors, required this.inherited, required this.titleStyle, required this.bodyStyle, required this.otherStyle});

  final SchemeColors colors;
  final List<Map<String, _Placeholder>> inherited;
  final Map<int, _Level> titleStyle;
  final Map<int, _Level> bodyStyle;
  final Map<int, _Level> otherStyle;
}

/// Resolves DrawingML colours (RGB, theme, system and preset colours, with
/// brightness modifiers) to RGB hex using the deck's theme.
class SchemeColors {
  SchemeColors(this.scheme, this.map);

  factory SchemeColors.from(XmlDocument? theme, XmlElement? clrMap) {
    final scheme = <String, String>{};
    final clrScheme = theme?.rootElement.deep('clrScheme').firstOrNull;
    for (final entry in clrScheme?.childElements ?? const <XmlElement>[]) {
      final c = entry.childElements.firstOrNull;
      final hex = c == null ? null : (c.name.local == 'sysClr' ? c.attr('lastClr') : c.attr('val'));
      if (hex != null) scheme[entry.name.local] = hex.toUpperCase();
    }
    final map = <String, String>{'bg1': 'lt1', 'tx1': 'dk1', 'bg2': 'lt2', 'tx2': 'dk2'};
    for (final a in clrMap?.attributes ?? const <XmlAttribute>[]) {
      map[a.name.local] = a.value;
    }
    return SchemeColors(scheme, map);
  }

  final Map<String, String> scheme;
  final Map<String, String> map;

  static const _preset = {
    'white': 'FFFFFF', 'black': '000000', 'red': 'FF0000', 'green': '008000', 'blue': '0000FF',
    'yellow': 'FFFF00', 'gray': '808080', 'grey': '808080', 'orange': 'FFA500',
  };

  /// Colour of a fill-bearing element (`spPr`, `bgPr`): solid or the first gradient stop.
  String? fill(XmlElement? owner) {
    if (owner == null || owner.kid('noFill') != null) return null;
    final solid = owner.kid('solidFill');
    if (solid != null) return resolve(solid);
    final stop = owner.kid('gradFill')?.kid('gsLst')?.kid('gs');
    return resolve(stop);
  }

  /// Colour of the first colour child of [holder] (e.g. `solidFill`, `bgRef`, `fontRef`).
  String? resolve(XmlElement? holder) {
    if (holder == null) return null;
    for (final c in holder.childElements) {
      String? hex;
      switch (c.name.local) {
        case 'srgbClr':
          hex = c.attr('val');
        case 'sysClr':
          hex = c.attr('lastClr') ?? (c.attr('val') == 'window' ? 'FFFFFF' : '000000');
        case 'prstClr':
          hex = _preset[c.attr('val')];
        case 'schemeClr':
          final name = c.attr('val');
          if (name == null || name == 'phClr') return null;
          hex = scheme[map[name] ?? name];
        case 'scrgbClr':
          int ch(String k) => ((int.tryParse(c.attr(k) ?? '') ?? 0) / 100000 * 255).round().clamp(0, 255);
          hex = [ch('r'), ch('g'), ch('b')].map((v) => v.toRadixString(16).padLeft(2, '0')).join();
        default:
          continue;
      }
      if (hex == null || hex.length != 6) return null;
      return _modify(hex.toUpperCase(), c);
    }
    return null;
  }

  static String _modify(String hex, XmlElement color) {
    var r = int.parse(hex.substring(0, 2), radix: 16) / 255;
    var g = int.parse(hex.substring(2, 4), radix: 16) / 255;
    var b = int.parse(hex.substring(4, 6), radix: 16) / 255;
    double v(XmlElement e) => (int.tryParse(e.attr('val') ?? '') ?? 100000) / 100000;
    var lumMod = 1.0, lumOff = 0.0;
    for (final m in color.childElements) {
      switch (m.name.local) {
        case 'lumMod':
          lumMod = v(m);
        case 'lumOff':
          lumOff = v(m);
        case 'tint':
          final t = v(m);
          r = 1 - (1 - r) * t;
          g = 1 - (1 - g) * t;
          b = 1 - (1 - b) * t;
        case 'shade':
          final t = v(m);
          r *= t;
          g *= t;
          b *= t;
      }
    }
    if (lumMod != 1 || lumOff != 0) {
      // Adjust lightness in HSL, as Office does.
      final maxC = [r, g, b].reduce((a, c) => a > c ? a : c);
      final minC = [r, g, b].reduce((a, c) => a < c ? a : c);
      var l = (maxC + minC) / 2;
      final d = maxC - minC;
      var h = 0.0, s = 0.0;
      if (d > 0) {
        s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC);
        if (maxC == r) {
          h = ((g - b) / d) % 6;
        } else if (maxC == g) {
          h = (b - r) / d + 2;
        } else {
          h = (r - g) / d + 4;
        }
        h /= 6;
      }
      l = (l * lumMod + lumOff).clamp(0.0, 1.0);
      double hue(double p, double q, double t) {
        t = t < 0 ? t + 1 : (t > 1 ? t - 1 : t);
        if (t < 1 / 6) return p + (q - p) * 6 * t;
        if (t < 1 / 2) return q;
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
        return p;
      }

      if (s == 0) {
        r = g = b = l;
      } else {
        final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        final p = 2 * l - q;
        r = hue(p, q, h + 1 / 3);
        g = hue(p, q, h);
        b = hue(p, q, h - 1 / 3);
      }
    }
    String h2(double x) => (x.clamp(0.0, 1.0) * 255).round().toRadixString(16).padLeft(2, '0');
    return '${h2(r)}${h2(g)}${h2(b)}'.toUpperCase();
  }
}
