import 'dart:typed_data';

import 'docx_reader.dart';
import 'ooxml_writer.dart';

/// Writes a [DocxDocument] as a standard .docx that opens in Microsoft Word.
///
/// New documents use Calibri 11 pt body text and Word's built-in style ids
/// (Title, Heading1-6) so headings show up in Word's navigation pane.
class DocxWriter {
  static const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  static const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const _wp = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
  static const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  static const _pic = 'http://schemas.openxmlformats.org/drawingml/2006/picture';

  static Uint8List write(DocxDocument doc, {String title = ''}) {
    final pkg = OoxmlPackageWriter();
    final rels = <(String, String, String)>[
      ('rId1', OoxmlPackageWriter.relType('styles'), 'styles.xml'),
    ];
    final body = StringBuffer();
    var imageCount = 0;
    var tableCount = 0;
    final hasLists = doc.blocks.any((b) => b is DocxParagraph && b.listLevel != null);
    for (final block in doc.blocks) {
      switch (block) {
        case DocxParagraph p:
          body.write(_paragraph(p));
        case DocxPageBreak _:
          body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
        case DocxTable t:
          tableCount++;
          body.write(_table(t, doc.page));
        case DocxImage img:
          imageCount++;
          final ext = OoxmlPackageWriter.imageExtension(img.bytes);
          final rid = 'rIdImg$imageCount';
          pkg.addBinary('word/media/image$imageCount.$ext', img.bytes);
          rels.add((rid, OoxmlPackageWriter.relType('image'), 'media/image$imageCount.$ext'));
          body.write(_image(img, rid, imageCount, doc.page));
      }
    }
    final page = doc.page;
    body.write('<w:sectPr><w:pgSz w:w="${page.width}" w:h="${page.height}"${page.width > page.height ? ' w:orient="landscape"' : ''}/>'
        '<w:pgMar w:top="${page.marginTop}" w:right="${page.marginRight}" w:bottom="${page.marginBottom}" w:left="${page.marginLeft}" '
        'w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>');

    pkg.addXml(
      'word/document.xml',
      '<w:document xmlns:w="$_w" xmlns:r="$_r" xmlns:wp="$_wp" xmlns:a="$_a" xmlns:pic="$_pic"><w:body>$body</w:body></w:document>',
      contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
    );
    pkg.addXml('word/styles.xml', _styles(withTables: tableCount > 0),
        contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml');
    if (hasLists) {
      rels.add(('rIdNumbering', OoxmlPackageWriter.relType('numbering'), 'numbering.xml'));
      pkg.addXml('word/numbering.xml', _numbering,
          contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml');
    }
    pkg.addXml('word/_rels/document.xml.rels', OoxmlPackageWriter.rels(rels));
    pkg.addRootRels('word/document.xml');
    pkg.addDocProps(title: title);
    return pkg.build();
  }

  static String _paragraph(DocxParagraph p) {
    final b = StringBuffer('<w:p>');
    final style = p.isTitle ? 'Title' : (p.headingLevel > 0 ? 'Heading${p.headingLevel.clamp(1, 6)}' : null);
    final jc = switch (p.align) {
      ParagraphAlign.center => 'center',
      ParagraphAlign.right => 'right',
      ParagraphAlign.justify => 'both',
      ParagraphAlign.left => null,
    };
    final list = p.listLevel;
    if (style != null || jc != null || list != null) {
      b.write('<w:pPr>');
      if (style != null) b.write('<w:pStyle w:val="$style"/>');
      if (list != null) b.write('<w:numPr><w:ilvl w:val="${list.clamp(0, 8)}"/><w:numId w:val="1"/></w:numPr>');
      if (jc != null) b.write('<w:jc w:val="$jc"/>');
      b.write('</w:pPr>');
    }
    for (final r in p.runs) {
      b.write('<w:r>');
      final props = StringBuffer();
      if (r.font != null) props.write('<w:rFonts w:ascii="${OoxmlPackageWriter.esc(r.font!)}" w:hAnsi="${OoxmlPackageWriter.esc(r.font!)}"/>');
      if (r.bold) props.write('<w:b/>');
      if (r.italic) props.write('<w:i/>');
      if (r.strike) props.write('<w:strike/>');
      if (r.color != null) props.write('<w:color w:val="${r.color}"/>');
      if (r.fontSizePt != null) props.write('<w:sz w:val="${(r.fontSizePt! * 2).round()}"/>');
      if (r.highlight != null) props.write('<w:highlight w:val="${r.highlight}"/>');
      if (r.underline) props.write('<w:u w:val="single"/>');
      if (props.isNotEmpty) b.write('<w:rPr>$props</w:rPr>');
      b.write(_text(r.text));
      b.write('</w:r>');
    }
    b.write('</w:p>');
    return b.toString();
  }

  /// Text with tabs and line breaks turned into their Word elements.
  static String _text(String text) {
    final b = StringBuffer();
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) b.write('<w:br/>');
      final tabs = lines[i].split('\t');
      for (var j = 0; j < tabs.length; j++) {
        if (j > 0) b.write('<w:tab/>');
        if (tabs[j].isNotEmpty) b.write('<w:t xml:space="preserve">${OoxmlPackageWriter.esc(tabs[j])}</w:t>');
      }
    }
    return b.toString();
  }

  static String _table(DocxTable t, DocxPageSetup page) {
    if (t.rows.isEmpty) return '';
    final cols = t.rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    if (cols == 0) return '';
    final colWidth = (page.width - page.marginLeft - page.marginRight) ~/ cols;
    final b = StringBuffer('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/></w:tblPr><w:tblGrid>');
    for (var c = 0; c < cols; c++) {
      b.write('<w:gridCol w:w="$colWidth"/>');
    }
    b.write('</w:tblGrid>');
    for (final row in t.rows) {
      b.write('<w:tr>');
      for (var c = 0; c < cols; c++) {
        final text = c < row.length ? row[c] : '';
        b.write('<w:tc><w:tcPr><w:tcW w:w="$colWidth" w:type="dxa"/></w:tcPr><w:p>');
        if (text.isNotEmpty) b.write('<w:r>${_text(text)}</w:r>');
        b.write('</w:p></w:tc>');
      }
      b.write('</w:tr>');
    }
    b.write('</w:tbl>');
    return b.toString();
  }

  static String _image(DocxImage img, String rid, int n, DocxPageSetup page) {
    final maxW = (page.width - page.marginLeft - page.marginRight) * 635; // twips -> EMU
    var cx = img.widthEmu ?? maxW;
    var cy = img.heightEmu ?? (cx * 0.75).round();
    if (cx > maxW) {
      cy = (cy * maxW / cx).round();
      cx = maxW;
    }
    return '<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="$cx" cy="$cy"/>'
        '<wp:docPr id="$n" name="Picture $n"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="$_pic"><pic:pic><pic:nvPicPr><pic:cNvPr id="$n" name="Picture $n"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';
  }

  /// One bulleted list definition (numId 1) with Word's default indents.
  static final _numbering = () {
    const chars = ['•', 'o', '▪'];
    final levels = StringBuffer();
    for (var l = 0; l < 9; l++) {
      final c = chars[l % 3];
      levels.write('<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="$c"/><w:lvlJc w:val="left"/>'
          '<w:pPr><w:ind w:left="${720 * (l + 1)}" w:hanging="360"/></w:pPr>'
          '<w:rPr><w:rFonts w:ascii="${c == 'o' ? 'Courier New' : 'Arial'}" w:hAnsi="${c == 'o' ? 'Courier New' : 'Arial'}" w:hint="default"/></w:rPr></w:lvl>');
    }
    return '<w:numbering xmlns:w="$_w"><w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>$levels</w:abstractNum>'
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>';
  }();

  static String _styles({required bool withTables}) {
    String heading(int level, int halfPoints) => '<w:style w:type="paragraph" w:styleId="Heading$level"><w:name w:val="heading $level"/>'
        '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>'
        '<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="${level == 1 ? 240 : 40}" w:after="0"/><w:outlineLvl w:val="${level - 1}"/></w:pPr>'
        '<w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi"/><w:color w:val="2F5496"/><w:sz w:val="$halfPoints"/></w:rPr></w:style>';
    return '<w:styles xmlns:w="$_w">'
        '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:eastAsia="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>'
        '<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>'
        '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="10"/><w:qFormat/>'
        '<w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:contextualSpacing/></w:pPr>'
        '<w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:kern w:val="28"/><w:sz w:val="56"/></w:rPr></w:style>'
        '${heading(1, 32)}${heading(2, 26)}${heading(3, 24)}${heading(4, 22)}${heading(5, 22)}${heading(6, 22)}'
        '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>'
        '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:semiHidden/>'
        '<w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>'
        '<w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>'
        '${withTables ? '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/>'
            '<w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders>'
            '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '</w:tblBorders></w:tblPr></w:style>' : ''}'
        '</w:styles>';
  }
}
