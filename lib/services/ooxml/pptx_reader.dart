import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'pptx_geometry.dart';
import 'xml_utils.dart';

export 'pptx_geometry.dart' show PptxGeometry;

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

/// An RGB colour (hex) with its opacity, 0 to 1.
class PptxColor {
  const PptxColor(this.hex, [this.alpha = 1]);

  final String hex;
  final double alpha;
}

class PptxGradientStop {
  const PptxGradientStop(this.position, this.color);

  /// 0 to 1 along the gradient.
  final double position;
  final PptxColor color;
}

/// How a shape or background is painted: one colour, a gradient or a picture.
class PptxFill {
  const PptxFill.solid(PptxColor this.color)
      : stops = const [],
        angle = 0,
        radial = false,
        centerX = 0.5,
        centerY = 0.5,
        image = null,
        colorMatrix = null,
        tile = false;

  const PptxFill.gradient(this.stops, {this.angle = 0, this.radial = false, this.centerX = 0.5, this.centerY = 0.5})
      : color = null,
        image = null,
        colorMatrix = null,
        tile = false;

  const PptxFill.picture(Uint8List this.image, {this.tile = false, this.colorMatrix})
      : color = null,
        stops = const [],
        angle = 0,
        radial = false,
        centerX = 0.5,
        centerY = 0.5;

  final PptxColor? color;
  final List<PptxGradientStop> stops;

  /// Direction of a straight gradient in degrees, clockwise from left-to-right.
  final double angle;

  /// A gradient that spreads out from a point.
  final bool radial;

  /// Where a radial gradient starts, 0 to 1 across and down.
  final double centerX;
  final double centerY;
  final Uint8List? image;

  /// Repeat the picture instead of stretching it.
  final bool tile;

  /// Recolouring of the picture (washout, greyscale, two-tone, see-through)
  /// as a 4x5 colour matrix on 0-255 values, or null.
  final List<double>? colorMatrix;

  /// One colour standing in for the whole fill.
  String? get mainHex => color?.hex ?? (stops.isEmpty ? null : stops[stops.length ~/ 2].color.hex);
}

/// An outline.
class PptxLine {
  const PptxLine(this.color, this.widthEmu, {this.arrowAtStart = false, this.arrowAtEnd = false});

  final PptxColor color;
  final int widthEmu;

  /// Arrowheads, on lines and connectors.
  final bool arrowAtStart;
  final bool arrowAtEnd;
}

/// A rectangle in EMU (914400 per inch) relative to the slide's top-left.
class EmuRect {
  const EmuRect(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;
}

class PptxShape {
  const PptxShape({
    required this.kind,
    this.rect,
    this.paragraphs = const [],
    this.imageBytes,
    this.fill,
    this.anchor = 't',
    this.ref,
    this.inGroup = false,
    this.placeholder = false,
    this.fillStyle,
    this.line,
    this.geometry,
    this.rotation = 0,
    this.flipH = false,
    this.flipV = false,
    this.decoration = false,
    this.table,
  });

  /// A table drawn in [rect].
  final PptxTable? table;

  /// The full fill (gradient, picture); [fill] is its main colour.
  final PptxFill? fillStyle;
  final PptxLine? line;

  /// The outline's shape; null is a plain rectangle.
  final PptxGeometry? geometry;

  /// Clockwise turn in degrees.
  final double rotation;
  final bool flipH;
  final bool flipV;

  /// Drawn by the slide master or layout (a logo, a coloured band): shown,
  /// but not part of the slide, so it can't be edited here.
  final bool decoration;

  /// Index of the shape's XML element in the editor's list for its slide,
  /// when the presentation was read for editing.
  final int? ref;

  /// Shapes inside a group are positioned by the group, so they can't be
  /// moved on their own.
  final bool inGroup;

  /// A layout placeholder ("Click to add title"); empty ones are only read
  /// for editing.
  final bool placeholder;

  final PptxShapeKind kind;
  final EmuRect? rect;
  final List<PptxParagraph> paragraphs;
  final Uint8List? imageBytes;
  final String? fill;

  /// Vertical text anchor inside the box: t, ctr or b.
  final String anchor;

  String get text => paragraphs.map((p) => p.text).join('\n');
}

/// A table on a slide. Column widths and row heights are in EMU.
class PptxTable {
  const PptxTable(this.columns, this.rows);

  final List<int> columns;
  final List<PptxTableRow> rows;
}

class PptxTableRow {
  const PptxTableRow(this.height, this.cells);

  final int height;
  final List<PptxTableCell> cells;
}

class PptxTableCell {
  const PptxTableCell({
    this.paragraphs = const [],
    this.fill,
    this.columnSpan = 1,
    this.rowSpan = 1,
    this.merged = false,
    this.left,
    this.right,
    this.top,
    this.bottom,
    this.anchor = 't',
  });

  final List<PptxParagraph> paragraphs;
  final PptxFill? fill;
  final int columnSpan;
  final int rowSpan;

  /// Covered by a neighbour that spans over it: not drawn.
  final bool merged;
  final PptxLine? left;
  final PptxLine? right;
  final PptxLine? top;
  final PptxLine? bottom;
  final String anchor;
}

class PptxSlide {
  const PptxSlide(this.shapes, {this.background, this.backgroundImage, this.backgroundFill});

  final List<PptxShape> shapes;

  /// The full background (gradient, tiled picture); [background] and
  /// [backgroundImage] are its main colour and picture.
  final PptxFill? backgroundFill;

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

  static PptxPresentation read(List<int> bytes) => readFrom(OoxmlPackage(bytes));

  /// Reads a presentation from [pkg]. When [slideParts] and [shapeElements]
  /// are given (for editing), they receive each slide's part name and the
  /// XML element of each shape, and shapes carry their index as `ref`.
  /// Editing also reads empty placeholders, so they can be typed into.
  static PptxPresentation readFrom(PackageSource pkg, {List<String>? slideParts, List<List<XmlElement>>? shapeElements}) {
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
      final elements = shapeElements == null ? null : <XmlElement>[];
      slides.add(readSlide(pkg, target, slideXml, pres.rootElement.kid('defaultTextStyle'), elements: elements));
      slideParts?.add(target);
      if (elements != null) shapeElements!.add(elements);
    }
    return PptxPresentation(slideWidth: width, slideHeight: height, slides: slides);
  }

  static PptxSlide readSlide(PackageSource pkg, String part, XmlDocument xml, XmlElement? defaultTextStyle, {List<XmlElement>? elements}) {
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
    final themeXml = themePart == null ? null : pkg.xml(themePart);
    // The layout and slide can remap the theme's colours (a dark layout
    // swaps text and background colours, say).
    final colors = SchemeColors.from(themeXml, master?.rootElement.kid('clrMap'))
        .withOverride(layout?.rootElement.kid('clrMapOvr')?.kid('overrideClrMapping'))
        .withOverride(xml.rootElement.kid('clrMapOvr')?.kid('overrideClrMapping'));
    final theme = _Theme(themeXml, themePart == null ? const {} : pkg.relationships(themePart));
    final txStyles = master?.rootElement.kid('txStyles');
    _SlideContext context(Map<String, String> partRels, {bool decoration = false}) => _SlideContext(
          pkg: pkg,
          rels: partRels,
          colors: colors,
          theme: theme,
          decoration: decoration,
          inherited: [
            if (layout != null) _placeholders(layout),
            if (master != null) _placeholders(master),
          ],
          titleStyle: _levels(txStyles?.kid('titleStyle')),
          bodyStyle: _levels(txStyles?.kid('bodyStyle')),
          otherStyle: _levels(defaultTextStyle ?? txStyles?.kid('otherStyle')),
        );

    // Pictures and shapes on the master and layout (a logo, a coloured
    // band) show under the slide's own, unless the slide or layout hides them.
    bool shows(XmlDocument? doc) => doc?.rootElement.attr('showMasterSp') != '0' && doc?.rootElement.attr('showMasterSp') != 'false';
    if (shows(xml)) {
      if (master != null && masterPart != null && shows(layout)) {
        final masterTree = master.rootElement.kid('cSld')?.kid('spTree');
        if (masterTree != null) _collect(masterTree, shapes, context(pkg.relationships(masterPart), decoration: true));
      }
      if (layout != null && layoutPart != null) {
        final layoutTree = layout.rootElement.kid('cSld')?.kid('spTree');
        if (layoutTree != null) _collect(layoutTree, shapes, context(pkg.relationships(layoutPart), decoration: true));
      }
    }
    if (tree != null) _collect(tree, shapes, context(rels), elements: elements);

    // Background: the first of slide, layout and master that defines one.
    PptxFill? background;
    for (final (owner, ownerPart) in [(xml, part), (layout, layoutPart), (master, masterPart)]) {
      final bg = owner?.rootElement.kid('cSld')?.kid('bg');
      if (bg == null || ownerPart == null) continue;
      final bgPr = bg.kid('bgPr');
      if (bgPr != null) {
        background = _readFill(bgPr, colors, pkg, pkg.relationships(ownerPart)).fill;
      } else {
        final ref = bg.kid('bgRef');
        background = theme.styleFill(ref, colors, pkg) ?? _solid(colors.color(ref));
      }
      break;
    }
    return PptxSlide(shapes, background: background?.mainHex, backgroundImage: background?.image, backgroundFill: background);
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

  static void _collect(XmlElement tree, List<PptxShape> out, _SlideContext ctx,
      {List<XmlElement>? elements, bool inGroup = false, _Transform transform = _Transform.identity, PptxFill? groupFill}) {
    int? register(XmlElement el) {
      if (elements == null) return null;
      elements.add(el);
      return elements.length - 1;
    }

    final colors = ctx.colors;
    for (final el in tree.childElements) {
      switch (el.name.local) {
        case 'sp' || 'cxnSp':
          final nvPr = el.kid(el.name.local == 'sp' ? 'nvSpPr' : 'nvCxnSpPr')?.kid('nvPr');
          final ph = nvPr?.kid('ph');
          // The master's and layout's placeholders only lend the slide their
          // place and style.
          if (ctx.decoration && ph != null) continue;
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
          final style = el.kid('style');
          // Shapes drawn with a theme style carry their default text colour here.
          final styleColor = colors.resolve(style?.kid('fontRef'));
          final paragraphs = <PptxParagraph>[];
          for (final p in txBody?.kids('p') ?? const <Never>[]) {
            paragraphs.add(_paragraph(p, chain, colors, styleColor, bulletByDefault: kind == PptxShapeKind.body && phType != 'subTitle'));
          }
          final spPr = el.kid('spPr');
          final geometry = PptxGeometry.read(spPr);
          final ownFill = _readFill(spPr, colors, ctx.pkg, ctx.rels, groupFill: groupFill);
          var fill = ownFill.found ? ownFill.fill : ctx.theme.styleFill(style?.kid('fillRef'), colors, ctx.pkg);
          if (geometry?.isLine ?? false) fill = null;
          final line = _readLine(spPr?.kid('ln'), style?.kid('lnRef'), ctx);
          final hasText = paragraphs.any((p) => p.text.trim().isNotEmpty);
          if (!hasText && fill == null && line == null && (elements == null || ph == null)) continue;
          final xfrm = spPr?.kid('xfrm');
          var rect = _rect(spPr);
          var anchor = txBody?.kid('bodyPr')?.attr('anchor');
          for (final parent in parents) {
            rect ??= parent.rect;
            anchor ??= parent.anchor;
          }
          out.add(PptxShape(
            kind: kind,
            rect: rect == null ? null : transform.apply(rect),
            paragraphs: paragraphs,
            fill: fill?.mainHex,
            fillStyle: fill,
            line: line,
            geometry: geometry,
            rotation: _angle(xfrm?.attr('rot')),
            flipH: _isTrue(xfrm?.attr('flipH')),
            flipV: _isTrue(xfrm?.attr('flipV')),
            anchor: anchor ?? 't',
            ref: ctx.decoration ? null : register(el),
            inGroup: inGroup,
            placeholder: ph != null,
            decoration: ctx.decoration,
          ));
        case 'pic':
          final id = el.kid('blipFill')?.kid('blip')?.attr('embed') ?? el.deep('blip').firstOrNull?.attr('embed');
          final target = id == null ? null : ctx.rels[id];
          final data = target == null ? null : ctx.pkg.bytes(target);
          if (data == null) continue;
          final spPr = el.kid('spPr');
          final rect = _rect(spPr);
          final xfrm = spPr?.kid('xfrm');
          final bytes = data is Uint8List ? data : Uint8List.fromList(data);
          final effects = _pictureEffects(el.kid('blipFill')?.kid('blip'), colors, null);
          out.add(PptxShape(
            kind: PptxShapeKind.picture,
            rect: rect == null ? null : transform.apply(rect),
            imageBytes: bytes,
            fillStyle: effects == null ? null : PptxFill.picture(bytes, colorMatrix: effects),
            geometry: PptxGeometry.read(spPr),
            line: _readLine(spPr?.kid('ln'), el.kid('style')?.kid('lnRef'), ctx),
            rotation: _angle(xfrm?.attr('rot')),
            flipH: _isTrue(xfrm?.attr('flipH')),
            flipV: _isTrue(xfrm?.attr('flipV')),
            ref: ctx.decoration ? null : register(el),
            inGroup: inGroup,
            decoration: ctx.decoration,
          ));
        case 'grpSp':
          final grpSpPr = el.kid('grpSpPr');
          final fill = _readFill(grpSpPr, colors, ctx.pkg, ctx.rels, groupFill: groupFill);
          _collect(el, out, ctx,
              elements: ctx.decoration ? null : elements,
              inGroup: true,
              transform: transform.then(_Transform.ofGroup(grpSpPr?.kid('xfrm'))),
              groupFill: fill.found ? fill.fill : groupFill);
        case 'graphicFrame':
          final frame = _rect(el);
          if (frame == null) continue;
          final data = el.kid('graphic')?.kid('graphicData');
          final uri = data?.attr('uri') ?? '';
          if (uri.endsWith('/table')) {
            final tbl = data?.kid('tbl');
            if (tbl == null) continue;
            out.add(PptxShape(
              kind: PptxShapeKind.text,
              rect: transform.apply(frame),
              table: _table(tbl, ctx),
              inGroup: inGroup,
              decoration: ctx.decoration,
            ));
          } else if (uri.endsWith('/ole')) {
            // An embedded object (a spreadsheet, say) shows its saved picture.
            final ole = data!.deep('oleObj').where((o) => o.kid('pic') != null).firstOrNull;
            if (ole != null) _collect(ole, out, ctx, elements: null, inGroup: inGroup, transform: transform, groupFill: groupFill);
          } else if (uri.endsWith('/diagram')) {
            // SmartArt: PowerPoint saves a drawing of it next to its data.
            final drawing = _diagramDrawing(data!, ctx);
            final tree = drawing == null ? null : ctx.pkg.xml(drawing)?.rootElement.kid('spTree');
            if (tree == null) continue;
            _collect(tree, out, ctx.withRels(ctx.pkg.relationships(drawing!), decoration: true),
                inGroup: true, transform: transform.then(_Transform(frame.x.toDouble(), 1, frame.y.toDouble(), 1)));
          }
        case 'AlternateContent':
          // Newer content with a fallback for older readers: use the fallback.
          final branch = el.kid('Fallback') ?? el.kid('Choice');
          if (branch != null) _collect(branch, out, ctx, elements: elements, inGroup: inGroup, transform: transform, groupFill: groupFill);
      }
    }
  }

  /// The recolouring set on a picture (`blip`), as one colour matrix.
  static List<double>? _pictureEffects(XmlElement? blip, SchemeColors colors, PptxColor? placeholder) {
    List<double>? result;
    void then(List<double> m) => result = result == null ? m : _combine(m, result!);
    double val(XmlElement e, String a, double fallback) => (int.tryParse(e.attr(a) ?? '') ?? fallback * 100000) / 100000;
    for (final e in blip?.childElements ?? const <XmlElement>[]) {
      switch (e.name.local) {
        case 'alphaModFix':
          final a = val(e, 'amt', 1);
          then([1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, a, 0]);
        case 'grayscl':
          then([for (var row = 0; row < 3; row++) ...[0.299, 0.587, 0.114, 0, 0], 0, 0, 0, 1, 0]);
        case 'duotone':
          // Dark parts take the first colour, light parts the second.
          final cs = [for (final c in e.childElements) colors.color(XmlElement(XmlName.parts('c'), const [], [c.copy()]), placeholder: placeholder)];
          if (cs.length < 2 || cs[0] == null || cs[1] == null) continue;
          double ch(String hex, int i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16).toDouble();
          final m = <double>[];
          for (var i = 0; i < 3; i++) {
            final from = ch(cs[0]!.hex, i), to = ch(cs[1]!.hex, i);
            final k = (to - from) / 255;
            m.addAll([0.299 * k, 0.587 * k, 0.114 * k, 0, from]);
          }
          then([...m, 0, 0, 0, 1, 0]);
        case 'lum':
          // Brightness shifts, contrast stretches around the middle.
          final bright = val(e, 'bright', 0);
          final contrast = val(e, 'contrast', 0);
          final c = contrast >= 0 ? 1 / math.max(0.01, 1 - contrast) : 1 + contrast;
          final off = 255 * (bright + (1 - c) / 2);
          then([c, 0, 0, 0, off, 0, c, 0, 0, off, 0, 0, c, 0, off, 0, 0, 0, 1, 0]);
        case 'biLevel':
          // Black and white at a threshold: a steep contrast on brightness.
          final t = val(e, 'thresh', 0.5);
          const k = 40.0;
          final row = [0.299 * k, 0.587 * k, 0.114 * k, 0.0, -255 * t * k];
          then([...row, ...row, ...row, 0, 0, 0, 1, 0]);
      }
    }
    return result;
  }

  /// [second] applied after [first], both 4x5 colour matrices.
  static List<double> _combine(List<double> second, List<double> first) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var v = c == 4 ? second[r * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          v += second[r * 5 + k] * first[k * 5 + c];
        }
        out[r * 5 + c] = v;
      }
    }
    return out;
  }

  /// The saved drawing of a SmartArt graphic.
  static String? _diagramDrawing(XmlElement graphicData, _SlideContext ctx) {
    final ids = graphicData.kid('relIds');
    final dataPart = ids == null ? null : ctx.rels[ids.attributes.where((a) => a.name.local == 'dm').firstOrNull?.value];
    final ext = dataPart == null ? null : ctx.pkg.xml(dataPart)?.rootElement.deep('dataModelExt').firstOrNull?.attr('relId');
    return (ext == null ? null : ctx.rels[ext]);
  }

  static const _defaultTableStyle = '{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}';

  static PptxTable _table(XmlElement tbl, _SlideContext ctx) {
    final colors = ctx.colors;
    final tblPr = tbl.kid('tblPr');
    bool flag(String name) => _isTrue(tblPr?.attr(name));
    final styleId = tblPr?.kid('tableStyleId')?.innerText.trim();
    XmlElement? style;
    if (styleId != null && styleId.isNotEmpty) {
      style = ctx.pkg.xml('ppt/tableStyles.xml')?.rootElement.kids('tblStyle').where((t) => t.attr('styleId') == styleId).firstOrNull;
      if (style == null && styleId == _defaultTableStyle) style = XmlDocument.parse(_mediumStyle2).rootElement;
    }
    final columns = [for (final c in tbl.kid('tblGrid')?.kids('gridCol') ?? const <XmlElement>[]) int.tryParse(c.attr('w') ?? '') ?? 0];
    final rowEls = tbl.kids('tr').toList();
    final rows = <PptxTableRow>[];
    for (var r = 0; r < rowEls.length; r++) {
      final cells = <PptxTableCell>[];
      final cellEls = rowEls[r].kids('tc').toList();
      for (var c = 0; c < cellEls.length; c++) {
        final tc = cellEls[c];
        // The style's parts that apply to this cell, weakest first.
        final dataRow = flag('firstRow') ? r - 1 : r;
        final dataCol = flag('firstCol') ? c - 1 : c;
        final parts = <XmlElement?>[
          style?.kid('wholeTbl'),
          if (flag('bandRow') && dataRow >= 0) style?.kid(dataRow.isEven ? 'band1H' : 'band2H'),
          if (flag('bandCol') && dataCol >= 0) style?.kid(dataCol.isEven ? 'band1V' : 'band2V'),
          if (flag('lastCol') && c == cellEls.length - 1) style?.kid('lastCol'),
          if (flag('firstCol') && c == 0) style?.kid('firstCol'),
          if (flag('lastRow') && r == rowEls.length - 1) style?.kid('lastRow'),
          if (flag('firstRow') && r == 0) style?.kid('firstRow'),
        ].whereType<XmlElement>().toList();
        PptxFill? fill;
        String? textColor;
        bool? bold;
        PptxLine? side(String outer, String inner, bool isEdge) {
          PptxLine? line;
          for (final part in parts) {
            final bdr = part.kid('tcStyle')?.kid('tcBdr');
            final ln = bdr?.kid(isEdge || part.name.local != 'wholeTbl' ? outer : inner)?.kid('ln');
            if (ln != null) line = _cellLine(ln, colors);
          }
          return line;
        }

        for (final part in parts) {
          final tcStyle = part.kid('tcStyle');
          final f = tcStyle?.kid('fill');
          if (f != null) {
            fill = _readFill(f, colors, ctx.pkg, ctx.rels).fill;
          } else if (tcStyle?.kid('fillRef') != null) {
            fill = ctx.theme.styleFill(tcStyle!.kid('fillRef'), colors, ctx.pkg);
          }
          final tx = part.kid('tcTxStyle');
          if (tx != null) {
            textColor = colors.resolve(tx) ?? textColor;
            final b = tx.attr('b');
            if (b != null) bold = b == 'on';
          }
        }
        final tcPr = tc.kid('tcPr');
        final own = _readFill(tcPr, colors, ctx.pkg, ctx.rels);
        if (own.found) fill = own.fill;
        PptxLine? border(String name, PptxLine? fallback) {
          final ln = tcPr?.kid(name);
          return ln == null ? fallback : _cellLine(ln, colors);
        }

        final span = int.tryParse(tc.attr('gridSpan') ?? '') ?? 1;
        // The table style's text colour wins over the deck's default text colour.
        final level = _Level(bold: bold, fill: textColor == null ? null : XmlDocument.parse('<solidFill><srgbClr val="$textColor"/></solidFill>').rootElement);
        final chain = [
          _levels(tc.kid('txBody')?.kid('lstStyle')),
          {for (var i = 0; i < 9; i++) i: level},
          ctx.otherStyle,
        ];
        cells.add(PptxTableCell(
          paragraphs: [for (final p in tc.kid('txBody')?.kids('p') ?? const <XmlElement>[]) _paragraph(p, chain, colors, null, bulletByDefault: false)],
          fill: fill,
          columnSpan: span,
          rowSpan: int.tryParse(tc.attr('rowSpan') ?? '') ?? 1,
          merged: _isTrue(tc.attr('hMerge')) || _isTrue(tc.attr('vMerge')),
          left: border('lnL', side('left', 'insideV', c == 0)),
          right: border('lnR', side('right', 'insideV', c + span >= cellEls.length)),
          top: border('lnT', side('top', 'insideH', r == 0)),
          bottom: border('lnB', side('bottom', 'insideH', r == rowEls.length - 1)),
          anchor: tcPr?.attr('anchor') ?? 't',
        ));
      }
      rows.add(PptxTableRow(int.tryParse(rowEls[r].attr('h') ?? '') ?? 0, cells));
    }
    return PptxTable(columns, rows);
  }

  static PptxLine? _cellLine(XmlElement ln, SchemeColors colors) {
    if (ln.kid('noFill') != null) return null;
    final c = colors.color(ln.kid('solidFill'));
    return c == null ? null : PptxLine(c, int.tryParse(ln.attr('w') ?? '') ?? 12700);
  }

  /// "Medium Style 2 - Accent 1", PowerPoint's default table style, for
  /// files that use it without including it.
  static const _mediumStyle2 = '<a:tblStyle xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" styleId="$_defaultTableStyle">'
      '<a:wholeTbl><a:tcTxStyle><a:schemeClr val="dk1"/></a:tcTxStyle><a:tcStyle><a:tcBdr>'
      '<a:left><a:ln w="12700"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:left>'
      '<a:right><a:ln w="12700"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:right>'
      '<a:top><a:ln w="12700"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:top>'
      '<a:bottom><a:ln w="12700"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:bottom>'
      '<a:insideH><a:ln w="12700"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:insideH>'
      '<a:insideV><a:ln w="12700"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:insideV>'
      '</a:tcBdr><a:fill><a:solidFill><a:schemeClr val="accent1"><a:tint val="20000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:wholeTbl>'
      '<a:band1H><a:tcStyle><a:fill><a:solidFill><a:schemeClr val="accent1"><a:tint val="40000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:band1H>'
      '<a:band1V><a:tcStyle><a:fill><a:solidFill><a:schemeClr val="accent1"><a:tint val="40000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:band1V>'
      '<a:lastCol><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:fill><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:lastCol>'
      '<a:firstCol><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:fill><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:firstCol>'
      '<a:lastRow><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:tcBdr><a:top><a:ln w="38100"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:top></a:tcBdr>'
      '<a:fill><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:lastRow>'
      '<a:firstRow><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:tcBdr><a:bottom><a:ln w="38100"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:bottom></a:tcBdr>'
      '<a:fill><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:firstRow></a:tblStyle>';

  static bool _isTrue(String? v) => v == '1' || v == 'true';

  /// DrawingML angles are in 60000ths of a degree.
  static double _angle(String? v) => (int.tryParse(v ?? '') ?? 0) / 60000;

  static PptxFill? _solid(PptxColor? c) => c == null ? null : PptxFill.solid(c);

  /// The fill set in [owner] (`spPr`, `bgPr`, a theme fill style). `found`
  /// is false when [owner] sets none, so a style's fill applies.
  static ({bool found, PptxFill? fill}) _readFill(XmlElement? owner, SchemeColors colors, PackageSource pkg, Map<String, String> rels,
      {PptxColor? placeholder, PptxFill? groupFill}) {
    for (final f in owner?.childElements ?? const <XmlElement>[]) {
      switch (f.name.local) {
        case 'noFill':
          return (found: true, fill: null);
        case 'solidFill':
          return (found: true, fill: _solid(colors.color(f, placeholder: placeholder)));
        case 'gradFill':
          final stops = <PptxGradientStop>[];
          for (final gs in f.kid('gsLst')?.kids('gs') ?? const <XmlElement>[]) {
            final c = colors.color(gs, placeholder: placeholder);
            if (c != null) stops.add(PptxGradientStop(((int.tryParse(gs.attr('pos') ?? '') ?? 0) / 100000).clamp(0.0, 1.0), c));
          }
          stops.sort((a, b) => a.position.compareTo(b.position));
          if (stops.isEmpty) return (found: true, fill: null);
          if (stops.length == 1) return (found: true, fill: PptxFill.solid(stops.first.color));
          final lin = f.kid('lin');
          final path = f.kid('path');
          if (lin == null && path != null) {
            // fillToRect insets (in 1000ths of a percent) frame the point it spreads from.
            final to = path.kid('fillToRect');
            double inset(String a) => (int.tryParse(to?.attr(a) ?? '') ?? 50000) / 100000;
            return (
              found: true,
              fill: PptxFill.gradient(stops,
                  radial: true, centerX: ((inset('l') + 1 - inset('r')) / 2).clamp(0.0, 1.0), centerY: ((inset('t') + 1 - inset('b')) / 2).clamp(0.0, 1.0)),
            );
          }
          return (found: true, fill: PptxFill.gradient(stops, angle: _angle(lin?.attr('ang'))));
        case 'blipFill':
          final id = f.kid('blip')?.attr('embed');
          final target = id == null ? null : rels[id];
          final data = target == null ? null : pkg.bytes(target);
          if (data == null) return (found: true, fill: null);
          return (
            found: true,
            fill: PptxFill.picture(data is Uint8List ? data : Uint8List.fromList(data),
                tile: f.kid('tile') != null, colorMatrix: _pictureEffects(f.kid('blip'), colors, placeholder)),
          );
        case 'pattFill':
          // A pattern of two colours: shown as their mix.
          final fg = colors.color(f.kid('fgClr'), placeholder: placeholder);
          final bg = colors.color(f.kid('bgClr'), placeholder: placeholder);
          if (fg == null || bg == null) return (found: true, fill: _solid(fg ?? bg));
          return (found: true, fill: PptxFill.solid(PptxColor(SchemeColors.mix(fg.hex, bg.hex), fg.alpha)));
        case 'grpFill':
          return (found: true, fill: groupFill);
      }
    }
    return (found: false, fill: null);
  }

  /// A shape's outline: its own `ln`, or the theme line style it refers to.
  static PptxLine? _readLine(XmlElement? ln, XmlElement? lnRef, _SlideContext ctx) {
    final colors = ctx.colors;
    final refColor = colors.color(lnRef);
    final styleLine = ctx.theme.lineStyle(lnRef);
    int width() => int.tryParse(ln?.attr('w') ?? '') ?? int.tryParse(styleLine?.attr('w') ?? '') ?? 9525;
    bool arrow(String end) {
      final type = (ln?.kid(end) ?? styleLine?.kid(end))?.attr('type');
      return type != null && type != 'none';
    }

    PptxLine make(PptxColor c) => PptxLine(c, width(), arrowAtStart: arrow('headEnd'), arrowAtEnd: arrow('tailEnd'));
    if (ln != null) {
      if (ln.kid('noFill') != null) return null;
      final solid = ln.kid('solidFill') ?? ln.kid('gradFill')?.kid('gsLst')?.kid('gs');
      if (solid != null) {
        final c = colors.color(solid);
        return c == null ? null : make(c);
      }
    }
    if (styleLine == null || styleLine.kid('noFill') != null) return null;
    final solid = styleLine.kid('solidFill') ?? styleLine.kid('gradFill')?.kid('gsLst')?.kid('gs');
    final c = solid == null ? refColor : colors.color(solid, placeholder: refColor);
    return c == null ? null : make(c);
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
  const _SlideContext({
    required this.pkg,
    required this.rels,
    required this.colors,
    required this.theme,
    required this.inherited,
    required this.titleStyle,
    required this.bodyStyle,
    required this.otherStyle,
    this.decoration = false,
  });

  final PackageSource pkg;

  /// Relationships of the part the shapes come from (slide, layout or master).
  final Map<String, String> rels;
  final SchemeColors colors;
  final _Theme theme;
  final bool decoration;
  final List<Map<String, _Placeholder>> inherited;
  final Map<int, _Level> titleStyle;
  final Map<int, _Level> bodyStyle;
  final Map<int, _Level> otherStyle;

  _SlideContext withRels(Map<String, String> rels, {bool decoration = false}) => _SlideContext(
        pkg: pkg,
        rels: rels,
        colors: colors,
        theme: theme,
        inherited: inherited,
        titleStyle: titleStyle,
        bodyStyle: bodyStyle,
        otherStyle: otherStyle,
        decoration: decoration || this.decoration,
      );
}

/// Maps a group's inner coordinates to the slide's.
class _Transform {
  const _Transform(this.dx, this.sx, this.dy, this.sy);

  static const identity = _Transform(0, 1, 0, 1);

  final double dx, sx, dy, sy;

  /// A group places its children, drawn in `chOff`/`chExt` space, at `off`/`ext`.
  factory _Transform.ofGroup(XmlElement? xfrm) {
    double v(String kid, String a) => double.tryParse(xfrm?.kid(kid)?.attr(a) ?? '') ?? 0;
    final chW = v('chExt', 'cx'), chH = v('chExt', 'cy');
    final sx = chW == 0 ? 1.0 : v('ext', 'cx') / chW;
    final sy = chH == 0 ? 1.0 : v('ext', 'cy') / chH;
    return _Transform(v('off', 'x') - v('chOff', 'x') * sx, sx, v('off', 'y') - v('chOff', 'y') * sy, sy);
  }

  /// [inner] first, then this.
  _Transform then(_Transform inner) => _Transform(dx + inner.dx * sx, inner.sx * sx, dy + inner.dy * sy, inner.sy * sy);

  EmuRect apply(EmuRect r) {
    if (identical(this, identity)) return r;
    return EmuRect((dx + r.x * sx).round(), (dy + r.y * sy).round(), (r.width * sx).round(), (r.height * sy).round());
  }
}

/// The theme's fill and line styles, which shapes and backgrounds refer to
/// by number.
class _Theme {
  _Theme(XmlDocument? theme, this.rels)
      : _fills = _list(theme, 'fillStyleLst'),
        _bgFills = _list(theme, 'bgFillStyleLst'),
        _lines = [...?_styles(theme, 'lnStyleLst')?.kids('ln')];

  final Map<String, String> rels;
  final List<XmlElement> _fills;
  final List<XmlElement> _bgFills;
  final List<XmlElement> _lines;

  static XmlElement? _styles(XmlDocument? theme, String name) => theme?.rootElement.deep(name).firstOrNull;
  static List<XmlElement> _list(XmlDocument? theme, String name) => [...?_styles(theme, name)?.childElements];

  /// The fill a `fillRef` or `bgRef` points to: 1 to 3 are fill styles,
  /// 1001 and up background styles. Its `phClr` is the reference's colour.
  PptxFill? styleFill(XmlElement? ref, SchemeColors colors, PackageSource pkg) {
    final idx = int.tryParse(ref?.attr('idx') ?? '') ?? 0;
    if (ref == null || idx == 0) return null;
    final list = idx >= 1001 ? _bgFills : _fills;
    final i = idx >= 1001 ? idx - 1001 : idx - 1;
    if (i < 0 || i >= list.length) return null;
    final holder = XmlElement(XmlName.parts('holder'), const [], [list[i].copy()]);
    return PptxReader._readFill(holder, colors, pkg, rels, placeholder: colors.color(ref)).fill;
  }

  /// The theme line a `lnRef` points to (1 to 3).
  XmlElement? lineStyle(XmlElement? ref) {
    final idx = int.tryParse(ref?.attr('idx') ?? '') ?? 0;
    return idx < 1 || idx > _lines.length ? null : _lines[idx - 1];
  }
}

/// Resolves DrawingML colours (RGB, theme, system and preset colours, with
/// brightness, saturation and transparency changes) using the deck's theme.
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
    return SchemeColors(scheme, const {'bg1': 'lt1', 'tx1': 'dk1', 'bg2': 'lt2', 'tx2': 'dk2'}).withOverride(clrMap);
  }

  final Map<String, String> scheme;
  final Map<String, String> map;

  /// The same theme with a colour mapping (`clrMap`, `overrideClrMapping`) applied.
  SchemeColors withOverride(XmlElement? mapping) {
    if (mapping == null || mapping.attributes.isEmpty) return this;
    return SchemeColors(scheme, {...map, for (final a in mapping.attributes) if (a.name.prefix == null) a.name.local: a.value});
  }

  static const _preset = {
    'white': 'FFFFFF', 'black': '000000', 'red': 'FF0000', 'green': '008000', 'blue': '0000FF',
    'yellow': 'FFFF00', 'gray': '808080', 'grey': '808080', 'orange': 'FFA500', 'darkBlue': '00008B',
    'darkGray': 'A9A9A9', 'darkGrey': 'A9A9A9', 'lightGray': 'D3D3D3', 'lightGrey': 'D3D3D3', 'darkRed': '8B0000',
    'darkGreen': '006400', 'navy': '000080', 'purple': '800080', 'silver': 'C0C0C0', 'maroon': '800000',
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
  String? resolve(XmlElement? holder) => color(holder)?.hex;

  /// Colour and opacity of the first colour child of [holder]. A `phClr`
  /// (in theme styles) stands for [placeholder].
  PptxColor? color(XmlElement? holder, {PptxColor? placeholder}) {
    if (holder == null) return null;
    for (final c in holder.childElements) {
      String? hex;
      var alpha = 1.0;
      switch (c.name.local) {
        case 'srgbClr':
          hex = c.attr('val');
        case 'sysClr':
          hex = c.attr('lastClr') ?? (c.attr('val') == 'window' ? 'FFFFFF' : '000000');
        case 'prstClr':
          hex = _preset[c.attr('val')];
        case 'schemeClr':
          final name = c.attr('val');
          if (name == null) return null;
          if (name == 'phClr') {
            if (placeholder == null) return null;
            hex = placeholder.hex;
            alpha = placeholder.alpha;
          } else {
            hex = scheme[map[name] ?? name];
          }
        case 'scrgbClr':
          int ch(String k) => (_linearToSrgb((int.tryParse(c.attr(k) ?? '') ?? 0) / 100000) * 255).round().clamp(0, 255);
          hex = [ch('r'), ch('g'), ch('b')].map((v) => v.toRadixString(16).padLeft(2, '0')).join();
        case 'hslClr':
          final h = (int.tryParse(c.attr('hue') ?? '') ?? 0) / 21600000;
          final s = (int.tryParse(c.attr('sat') ?? '') ?? 0) / 100000;
          final l = (int.tryParse(c.attr('lum') ?? '') ?? 0) / 100000;
          final (r, g, b) = _fromHsl(h, s, l);
          hex = _hex(r, g, b);
        default:
          continue;
      }
      if (hex == null || hex.length != 6 || int.tryParse(hex, radix: 16) == null) return null;
      return _modify(hex.toUpperCase(), alpha, c);
    }
    return null;
  }

  /// The colour halfway between two.
  static String mix(String a, String b) {
    final x = int.parse(a, radix: 16), y = int.parse(b, radix: 16);
    int ch(int v, int shift) => (v >> shift) & 0xFF;
    return _hex((ch(x, 16) + ch(y, 16)) / 510, (ch(x, 8) + ch(y, 8)) / 510, (ch(x, 0) + ch(y, 0)) / 510);
  }

  static double _linearToSrgb(double v) => v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;

  static String _hex(double r, double g, double b) {
    String h2(double x) => (x.clamp(0.0, 1.0) * 255).round().toRadixString(16).padLeft(2, '0');
    return '${h2(r)}${h2(g)}${h2(b)}'.toUpperCase();
  }

  static (double, double, double) _toHsl(double r, double g, double b) {
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final l = (maxC + minC) / 2;
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
    return (h, s, l);
  }

  static (double, double, double) _fromHsl(double h, double s, double l) {
    if (s == 0) return (l, l, l);
    double hue(double p, double q, double t) {
      t = t < 0 ? t + 1 : (t > 1 ? t - 1 : t);
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    return (hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3));
  }

  static PptxColor _modify(String hex, double alpha, XmlElement color) {
    var r = int.parse(hex.substring(0, 2), radix: 16) / 255;
    var g = int.parse(hex.substring(2, 4), radix: 16) / 255;
    var b = int.parse(hex.substring(4, 6), radix: 16) / 255;
    double v(XmlElement e) => (int.tryParse(e.attr('val') ?? '') ?? 100000) / 100000;
    // Changes apply in order, as Office applies them.
    for (final m in color.childElements) {
      switch (m.name.local) {
        case 'alpha':
          alpha = v(m);
        case 'alphaMod':
          alpha *= v(m);
        case 'alphaOff':
          alpha += v(m);
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
        case 'inv':
          r = 1 - r;
          g = 1 - g;
          b = 1 - b;
        case 'gray':
          r = g = b = 0.3 * r + 0.59 * g + 0.11 * b;
        case 'lumMod' || 'lumOff' || 'satMod' || 'satOff' || 'hueMod' || 'hueOff' || 'comp':
          var (h, s, l) = _toHsl(r, g, b);
          switch (m.name.local) {
            case 'lumMod':
              l *= v(m);
            case 'lumOff':
              l += v(m);
            case 'satMod':
              s *= v(m);
            case 'satOff':
              s += v(m);
            case 'hueMod':
              h *= v(m);
            case 'hueOff':
              h += (int.tryParse(m.attr('val') ?? '') ?? 0) / 21600000;
            case 'comp':
              h += 0.5;
          }
          (r, g, b) = _fromHsl(h % 1, s.clamp(0.0, 1.0), l.clamp(0.0, 1.0));
      }
    }
    return PptxColor(_hex(r, g, b), alpha.clamp(0.0, 1.0));
  }
}
