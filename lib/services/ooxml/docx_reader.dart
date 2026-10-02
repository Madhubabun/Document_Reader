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
  });

  final List<DocxRun> runs;

  /// 0 for body text, 1-6 for headings.
  final int headingLevel;
  final bool isTitle;

  /// Non-null when the paragraph is a list item (bullet or numbered).
  final int? listLevel;
  final ParagraphAlign align;

  String get text => runs.map((r) => r.text).join();
}

class DocxTable extends DocxBlock {
  const DocxTable(this.rows);

  final List<List<String>> rows;
}

class DocxImage extends DocxBlock {
  const DocxImage(this.bytes, {this.widthEmu, this.heightEmu});

  final Uint8List bytes;
  final int? widthEmu;
  final int? heightEmu;
}

class DocxDocument {
  const DocxDocument(this.blocks);

  final List<DocxBlock> blocks;

  String get plainText => blocks
      .map((b) => switch (b) {
            DocxParagraph p => p.text,
            DocxTable t => t.rows.map((r) => r.join('\t')).join('\n'),
            DocxImage _ => '',
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
    final body = doc.rootElement.kid('body');
    if (body == null) return const DocxDocument([]);

    final styleNames = <String, String>{};
    final styles = pkg.xml('word/styles.xml');
    if (styles != null) {
      for (final s in styles.rootElement.kids('style')) {
        final id = s.attr('styleId');
        final name = s.kid('name')?.attr('val');
        if (id != null && name != null) styleNames[id] = name.toLowerCase();
      }
    }
    final rels = pkg.relationships(mainPart);
    final reader = _BodyReader(pkg, rels, styleNames);
    return DocxDocument(reader.readBlocks(body));
  }
}

class _BodyReader {
  _BodyReader(this.pkg, this.rels, this.styleNames);

  final OoxmlPackage pkg;
  final Map<String, String> rels;
  final Map<String, String> styleNames;

  List<DocxBlock> readBlocks(XmlElement container) {
    final blocks = <DocxBlock>[];
    for (final el in container.childElements) {
      switch (el.name.local) {
        case 'p':
          blocks.addAll(_paragraph(el));
        case 'tbl':
          blocks.add(_table(el));
        case 'sdt':
          final content = el.kid('sdtContent');
          if (content != null) blocks.addAll(readBlocks(content));
      }
    }
    return blocks;
  }

  Iterable<DocxBlock> _paragraph(XmlElement p) sync* {
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
    yield DocxParagraph(runs: runs, headingLevel: heading, isTitle: isTitle, listLevel: listLevel, align: align);
    yield* images;
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
    final data = target == null ? null : pkg.bytes(target);
    if (data == null) return null;
    final extent = run.deep('extent').firstOrNull;
    return DocxImage(
      Uint8List.fromList(data),
      widthEmu: int.tryParse(extent?.attr('cx') ?? ''),
      heightEmu: int.tryParse(extent?.attr('cy') ?? ''),
    );
  }

  DocxTable _table(XmlElement tbl) {
    final rows = <List<String>>[];
    for (final tr in tbl.kids('tr')) {
      rows.add([
        for (final tc in tr.kids('tc'))
          tc.kids('p').map((p) => p.deep('t').map((t) => t.innerText).join()).join('\n'),
      ]);
    }
    return DocxTable(rows);
  }
}
