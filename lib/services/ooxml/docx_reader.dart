import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'xml_utils.dart';

enum ParagraphAlign { left, center, right, justify }

class DocxRun {
  const DocxRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.fontSizePt,
    this.color,
    this.highlight,
    this.font,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final double? fontSizePt;

  /// RGB hex like `1F2937`, or null for automatic.
  final String? color;
  final String? highlight;
  final String? font;
}

sealed class DocxBlock {
  const DocxBlock();
}

class DocxParagraph extends DocxBlock {
  const DocxParagraph({
    required this.runs,
    this.headingLevel = 0,
    this.isTitle = false,
    this.listLevel,
    this.align = ParagraphAlign.left,
    this.ref,
  });

  final List<DocxRun> runs;

  /// Position of the paragraph's `<w:p>` in the editor's paragraph list,
  /// when the document was read for editing.
  final int? ref;

  /// 0 for body text, 1-6 for headings.
  final int headingLevel;
  final bool isTitle;

  /// Non-null when the paragraph is a list item (bullet or numbered).
  final int? listLevel;
  final ParagraphAlign align;

  String get text => runs.map((r) => r.text).join();
}

class DocxTable extends DocxBlock {
  const DocxTable(this.rows, {this.ref});

  final List<List<String>> rows;

  /// Position of the `<w:tbl>` in the editor's table list, when editing.
  final int? ref;
}

class DocxImage extends DocxBlock {
  const DocxImage(this.bytes, {this.widthEmu, this.heightEmu});

  final Uint8List bytes;
  final int? widthEmu;
  final int? heightEmu;
}

/// A hard page break (`<w:br w:type="page"/>`).
class DocxPageBreak extends DocxBlock {
  const DocxPageBreak();
}

/// Page geometry from the last section, in twentieths of a point.
class DocxPageSetup {
  const DocxPageSetup({this.width = 11906, this.height = 16838, this.marginTop = 1440, this.marginRight = 1440, this.marginBottom = 1440, this.marginLeft = 1440});

  static const a4 = DocxPageSetup();
  static const letter = DocxPageSetup(width: 12240, height: 15840);

  final int width;
  final int height;
  final int marginTop;
  final int marginRight;
  final int marginBottom;
  final int marginLeft;
}

class DocxDocument {
  const DocxDocument(this.blocks, {this.page = DocxPageSetup.a4});

  final List<DocxBlock> blocks;
  final DocxPageSetup page;

  String get plainText => blocks
      .map((b) => switch (b) {
            DocxParagraph p => p.text,
            DocxTable t => t.rows.map((r) => r.join('\t')).join('\n'),
            DocxImage _ || DocxPageBreak _ => '',
          })
      .where((t) => t.isNotEmpty)
      .join('\n');
}

/// Reads the visible content of a .docx (WordprocessingML) file.
class DocxReader {
  static DocxDocument read(List<int> bytes) {
    final pkg = OoxmlPackage(bytes);
    const mainPart = 'word/document.xml';
    final doc = pkg.xml(mainPart);
    if (doc == null) throw OoxmlFormatException('Not a Word document (word/document.xml missing).');
    return readParts(document: doc, styles: pkg.xml('word/styles.xml'), rels: pkg.relationships(mainPart), bytes: pkg.bytes);
  }

  /// Reads already-parsed parts. With [paragraphs] and [tables], every
  /// `<w:p>` and `<w:tbl>` that becomes a block is added to them and the
  /// block's `ref` is its index, so an editor can find the XML again.
  static DocxDocument readParts({
    required XmlDocument document,
    XmlDocument? styles,
    Map<String, String> rels = const {},
    required List<int>? Function(String path) bytes,
    List<XmlElement>? paragraphs,
    List<XmlElement>? tables,
  }) {
    final body = document.rootElement.kid('body');
    if (body == null) return const DocxDocument([]);
    final reader = _BodyReader(bytes, rels, styleNames(styles), paragraphs, tables);
    return DocxDocument(reader.readBlocks(body), page: _pageSetup(body.kid('sectPr')));
  }

  /// Style id -> lower-case style name, e.g. `Heading1` -> `heading 1`.
  static Map<String, String> styleNames(XmlDocument? styles) => {
        for (final s in styles?.rootElement.kids('style') ?? const <XmlElement>[])
          if (s.attr('styleId') != null && s.kid('name')?.attr('val') != null) s.attr('styleId')!: s.kid('name')!.attr('val')!.toLowerCase(),
      };

  /// Reads one paragraph the way [read] does, for refreshing a single
  /// paragraph after it was edited.
  static DocxParagraph readParagraph(XmlElement p, Map<String, String> styleNames, {int? ref}) =>
      _BodyReader((_) => null, const {}, styleNames, null, null)._paragraph(p, ref: ref).whereType<DocxParagraph>().first;

  static DocxPageSetup _pageSetup(XmlElement? sectPr) {
    final size = sectPr?.kid('pgSz');
    final mar = sectPr?.kid('pgMar');
    int read(XmlElement? el, String name, int fallback) => int.tryParse(el?.attr(name) ?? '') ?? fallback;
    var width = read(size, 'w', 11906);
    var height = read(size, 'h', 16838);
    if (size?.attr('orient') == 'landscape' && width < height) (width, height) = (height, width);
    return DocxPageSetup(
      width: width,
      height: height,
      marginTop: read(mar, 'top', 1440).abs(),
      marginRight: read(mar, 'right', 1440),
      marginBottom: read(mar, 'bottom', 1440).abs(),
      marginLeft: read(mar, 'left', 1440),
    );
  }
}

class _BodyReader {
  _BodyReader(this.bytes, this.rels, this.styleNames, this.paragraphs, this.tables);

  final List<int>? Function(String path) bytes;
  final Map<String, String> rels;
  final Map<String, String> styleNames;
  final List<XmlElement>? paragraphs;
  final List<XmlElement>? tables;

  List<DocxBlock> readBlocks(XmlElement container) {
    final blocks = <DocxBlock>[];
    for (final el in container.childElements) {
      switch (el.name.local) {
        case 'p':
          final list = paragraphs;
          int? ref;
          if (list != null) {
            ref = list.length;
            list.add(el);
          }
          blocks.addAll(_paragraph(el, ref: ref));
        case 'tbl':
          final list = tables;
          int? ref;
          if (list != null) {
            ref = list.length;
            list.add(el);
          }
          blocks.add(_table(el, ref: ref));
        case 'sdt':
          final content = el.kid('sdtContent');
          if (content != null) blocks.addAll(readBlocks(content));
      }
    }
    return blocks;
  }

  Iterable<DocxBlock> _paragraph(XmlElement p, {int? ref}) sync* {
    final pPr = p.kid('pPr');
    final styleId = pPr?.kid('pStyle')?.attr('val');
    final styleName = styleId == null ? '' : (styleNames[styleId] ?? styleId.toLowerCase());
    var heading = 0;
    final match = RegExp(r'heading\s*(\d)').firstMatch(styleName);
    if (match != null) heading = int.parse(match.group(1)!).clamp(1, 6);
    final outline = pPr?.kid('outlineLvl')?.attr('val');
    if (heading == 0 && outline != null) heading = ((int.tryParse(outline) ?? 8) + 1).clamp(1, 9);
    if (heading > 6) heading = 0;
    final isTitle = styleName == 'title';

    int? listLevel;
    final numPr = pPr?.kid('numPr');
    if (numPr != null) {
      listLevel = int.tryParse(numPr.kid('ilvl')?.attr('val') ?? '0') ?? 0;
    } else if (styleName.startsWith('list')) {
      listLevel = 0;
    }

    final align = switch (pPr?.kid('jc')?.attr('val')) {
      'center' => ParagraphAlign.center,
      'right' || 'end' => ParagraphAlign.right,
      'both' || 'distribute' => ParagraphAlign.justify,
      _ => ParagraphAlign.left,
    };

    final runs = <DocxRun>[];
    final images = <DocxImage>[];
    void collectRuns(XmlElement parent) {
      for (final child in parent.childElements) {
        switch (child.name.local) {
          case 'r':
            final run = _run(child);
            if (run != null) runs.add(run);
            for (final blip in child.deep('blip')) {
              final image = _image(blip, child);
              if (image != null) images.add(image);
            }
          case 'hyperlink' || 'ins' || 'smartTag' || 'fldSimple':
            collectRuns(child);
          case 'sdt':
            final content = child.kid('sdtContent');
            if (content != null) collectRuns(content);
        }
      }
    }

    collectRuns(p);
    if (pPr?.kid('pageBreakBefore')?.isOn == true) yield const DocxPageBreak();
    yield DocxParagraph(runs: runs, headingLevel: heading, isTitle: isTitle, listLevel: listLevel, align: align, ref: ref);
    yield* images;
    if (p.deep('br').any((br) => br.attr('type') == 'page')) {
      yield const DocxPageBreak();
    }
  }

  DocxRun? _run(XmlElement r) {
    final buffer = StringBuffer();
    for (final child in r.childElements) {
      switch (child.name.local) {
        case 't':
          buffer.write(child.innerText);
        case 'tab':
          buffer.write('\t');
        case 'br' || 'cr':
          buffer.write('\n');
        case 'noBreakHyphen':
          buffer.write('-');
      }
    }
    if (buffer.isEmpty) return null;
    final rPr = r.kid('rPr');
    final size = rPr?.kid('sz')?.attr('val');
    final color = rPr?.kid('color')?.attr('val');
    final underline = rPr?.kid('u');
    return DocxRun(
      buffer.toString(),
      bold: rPr?.kid('b')?.isOn ?? false,
      italic: rPr?.kid('i')?.isOn ?? false,
      underline: underline != null && underline.isOn,
      strike: rPr?.kid('strike')?.isOn ?? false,
      fontSizePt: size == null ? null : (int.tryParse(size) ?? 0) / 2,
      color: (color == null || color == 'auto') ? null : color,
      highlight: rPr?.kid('highlight')?.attr('val'),
      font: rPr?.kid('rFonts')?.attr('ascii'),
    );
  }

  DocxImage? _image(XmlElement blip, XmlElement run) {
    final id = blip.attr('embed');
    final target = id == null ? null : rels[id];
    final data = target == null ? null : bytes(target);
    if (data == null) return null;
    final extent = run.deep('extent').firstOrNull;
    return DocxImage(
      // Keep the same list when it already is one, so pictures aren't decoded again after edits.
      data is Uint8List ? data : Uint8List.fromList(data),
      widthEmu: int.tryParse(extent?.attr('cx') ?? ''),
      heightEmu: int.tryParse(extent?.attr('cy') ?? ''),
    );
  }

  DocxTable _table(XmlElement tbl, {int? ref}) {
    final rows = <List<String>>[];
    for (final tr in tbl.kids('tr')) {
      rows.add([
        for (final tc in tr.kids('tc'))
          tc.kids('p').map((p) => p.deep('t').map((t) => t.innerText).join()).join('\n'),
      ]);
    }
    return DocxTable(rows, ref: ref);
  }
}
