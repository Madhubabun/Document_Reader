import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_reader/screens/office/slides_view.dart';
import 'package:doc_reader/services/convert/office_to_pdf.dart';
import 'package:doc_reader/services/convert/pptx_pdf_shapes.dart';
import 'package:doc_reader/services/ooxml/pptx_geometry.dart';
import 'package:doc_reader/services/ooxml/pptx_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'convert_test.dart' show testFonts;
import 'package:doc_reader/services/ooxml/xml_utils.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

const _a = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"';
const _rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// test/fixtures/sample.pptx with some parts changed: [edits] rewrite a
/// part's XML, [add] puts new files in.
List<int> patched({Map<String, String Function(String xml)> edits = const {}, Map<String, List<int>> add = const {}}) {
  final source = ZipDecoder().decodeBytes(File('test/fixtures/sample.pptx').readAsBytesSync());
  final out = Archive();
  final seen = <String>{};
  for (final f in source.files) {
    var bytes = f.content as List<int>;
    final edit = edits[f.name];
    if (edit != null) bytes = utf8.encode(edit(utf8.decode(bytes)));
    seen.add(f.name);
    out.addFile(ArchiveFile.bytes(f.name, bytes));
  }
  for (final e in edits.entries) {
    if (!seen.contains(e.key)) out.addFile(ArchiveFile.bytes(e.key, utf8.encode(e.value(''))));
  }
  for (final e in add.entries) {
    out.addFile(ArchiveFile.bytes(e.key, e.value));
  }
  return ZipEncoder().encodeBytes(out);
}

String Function(String) addRel(String id, String type, String target) =>
    (xml) => xml.replaceFirst('</Relationships>', '<Relationship Id="$id" Type="$_rel/$type" Target="$target"/></Relationships>');

/// Puts [shapes] at the end of slide 1's shape tree.
String Function(String) slideShapes(String shapes) => (xml) => xml.replaceFirst('</p:spTree>', '$shapes</p:spTree>');

Uint8List jpeg(int r, int g, int b) => Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)..clear(img.ColorRgb8(r, g, b))));

String rectSp(int id, String spPrInner, {String style = '', String text = ''}) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="Shape $id"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="100" y="200"/><a:ext cx="3000" cy="4000"/></a:xfrm>$spPrInner</p:spPr>$style'
    '${text.isEmpty ? '' : '<p:txBody><a:bodyPr/><a:p><a:r><a:t>$text</a:t></a:r></a:p></p:txBody>'}</p:sp>';

/// A two-column table in the default style with a merged second row.
String tableXml() {
    String cell(String t) => '<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>$t</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>';
    return '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="50" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>'
        '<p:xfrm><a:off x="500" y="600"/><a:ext cx="2000" cy="800"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">'
        '<a:tbl><a:tblPr firstRow="1" bandRow="1"><a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId></a:tblPr>'
        '<a:tblGrid><a:gridCol w="1000"/><a:gridCol w="1000"/></a:tblGrid>'
        '<a:tr h="400">${cell('Name')}${cell('Score')}</a:tr>'
        '<a:tr h="400"><a:tc gridSpan="2"><a:txBody><a:bodyPr/><a:p><a:r><a:t>Both</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc><a:tc hMerge="1"><a:txBody><a:bodyPr/><a:p/></a:txBody><a:tcPr/></a:tc></a:tr>'
        '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>';
}

/// A deck whose background is the theme's grey texture recoloured in two tones of C08040.
List<int> duotoneDeck({Map<String, String Function(String xml)> more = const {}}) {
    // The theme's third background style: a picture in two tones of the colour asked for.
    const style = '<a:blipFill><a:blip r:embed="rIdTex"><a:duotone><a:schemeClr val="phClr"><a:shade val="50000"/></a:schemeClr>'
        '<a:schemeClr val="phClr"/></a:duotone></a:blip><a:tile tx="0" ty="0" sx="100000" sy="100000" flip="none" algn="tl"/></a:blipFill>';
    return patched(edits: {
      ...more,
      'ppt/theme/theme1.xml': (x) => x.replaceFirst('</a:bgFillStyleLst>', '$style</a:bgFillStyleLst>'),
      'ppt/theme/_rels/theme1.xml.rels': (_) =>
          '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rIdTex" Type="$_rel/image" Target="../media/texture.jpeg"/></Relationships>',
      'ppt/slideMasters/slideMaster1.xml': (x) => x.replaceFirst('<p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef>', '<p:bgRef idx="1004"><a:srgbClr val="C08040"/></p:bgRef>'),
    }, add: {
      'ppt/media/texture.jpeg': jpeg(128, 128, 128),
    });
}

void main() {
  edgeCases();
  test('pictures and shapes on the master show under every slide, unless hidden', () {
    final logo = '<p:pic><p:nvPicPr><p:cNvPr id="9" name="Logo"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>'
        '<p:blipFill><a:blip r:embed="rIdLogo"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
        '<p:spPr><a:xfrm><a:off x="10" y="20"/><a:ext cx="300" cy="400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>';
    final deck = patched(edits: {
      'ppt/slideMasters/slideMaster1.xml': (x) => x.replaceFirst('</p:spTree>', '$logo</p:spTree>'),
      'ppt/slideMasters/_rels/slideMaster1.xml.rels': addRel('rIdLogo', 'image', '../media/logo.jpeg'),
      // Slide 2 turns master graphics off.
      'ppt/slides/slide2.xml': (x) => x.replaceFirst('<p:sld ', '<p:sld showMasterSp="0" '),
    }, add: {
      'ppt/media/logo.jpeg': jpeg(120, 40, 160),
    });
    final pres = PptxReader.read(deck);
    final first = pres.slides[0].shapes.first;
    expect(first.kind, PptxShapeKind.picture);
    expect(first.decoration, isTrue);
    expect(first.ref, isNull);
    expect(first.rect!.x, 10);
    // The master's placeholders are not drawn as shapes of their own.
    expect(pres.slides[0].shapes.where((s) => s.decoration), hasLength(1));
    expect(pres.slides[1].shapes.where((s) => s.decoration), isEmpty);
  });

  test('editing keeps slide shapes addressable when the master adds graphics', () {
    final deck = patched(edits: {
      'ppt/slideMasters/slideMaster1.xml': (x) => x.replaceFirst('</p:spTree>', '${rectSp(30, '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>')}</p:spTree>'),
    });
    final elements = <List<XmlElement>>[];
    final editable = PptxReader.readFrom(OoxmlPackage(deck), slideParts: <String>[], shapeElements: elements);
    final shapes = editable.slides.first.shapes;
    expect(shapes.first.decoration, isTrue);
    expect(shapes.map((s) => s.ref), [null, 0, 1]);
    // Refs point at the slide's own shapes, not the master's.
    expect(elements.first.map((e) => e.attr('name') ?? e.descendantElements.firstWhere((d) => d.name.local == 'cNvPr').getAttribute('name')), ['Title 1', 'Subtitle 2']);
  });

  test('a theme background picture is recoloured with its two tones', () {
    final deck = duotoneDeck();
    final fill = PptxReader.read(deck).slides.first.backgroundFill!;
    expect(fill.image, isNotNull);
    expect(fill.tile, isTrue);
    final m = fill.colorMatrix!;
    // Black becomes the darker tone (half of C0 80 40), white the colour itself.
    expect([m[4], m[9], m[14]].map((v) => v.round()), [96, 64, 32]);
    expect([for (var row = 0; row < 3; row++) ((m[row * 5] + m[row * 5 + 1] + m[row * 5 + 2]) * 255 + m[row * 5 + 4]).round()], [192, 128, 64]);
  });

  test('gradients, theme-styled shapes, outlines, groups and colour remapping are read', () {
    final grad = rectSp(20, '<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom><a:gradFill><a:gsLst><a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs>'
        '<a:gs pos="0"><a:srgbClr val="FF0000"><a:alpha val="50000"/></a:srgbClr></a:gs></a:gsLst><a:lin ang="5400000"/></a:gradFill>'
        '<a:ln w="25400"><a:solidFill><a:srgbClr val="00FF00"/></a:solidFill></a:ln>');
    // No fill of its own: the theme style gives it accent1 and a darker outline.
    final styled = rectSp(21, '<a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom>',
        style: '<p:style><a:lnRef idx="2"><a:schemeClr val="accent1"><a:shade val="50000"/></a:schemeClr></a:lnRef>'
            '<a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef>'
            '<a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></p:style>',
        text: 'Styled');
    final group = '<p:grpSp><p:nvGrpSpPr><p:cNvPr id="40" name="Group"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr><a:xfrm><a:off x="1000" y="1000"/><a:ext cx="2000" cy="2000"/><a:chOff x="0" y="0"/><a:chExt cx="1000" cy="1000"/></a:xfrm></p:grpSpPr>'
        '<p:sp><p:nvSpPr><p:cNvPr id="41" name="In group"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="100" y="200"/><a:ext cx="300" cy="400"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:schemeClr val="bg1"/></a:solidFill></p:spPr></p:sp></p:grpSp>';
    final deck = patched(edits: {
      'ppt/slides/slide1.xml': (x) => slideShapes('$grad$styled$group')(x)
          .replaceFirst('<a:masterClrMapping/>', '<a:overrideClrMapping bg1="dk1" tx1="lt1" bg2="dk2" tx2="lt2" accent1="accent1" accent2="accent2" '
              'accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'),
    });
    final shapes = PptxReader.read(deck).slides.first.shapes;
    final g = shapes.firstWhere((s) => s.fillStyle?.stops.isNotEmpty ?? false);
    expect(g.geometry!.preset, 'ellipse');
    expect(g.fillStyle!.stops.map((s) => s.color.hex), ['FF0000', '0000FF']);
    expect(g.fillStyle!.stops.first.color.alpha, closeTo(0.5, 0.001));
    expect(g.fillStyle!.angle, 90);
    expect(g.line!.color.hex, '00FF00');
    expect(g.line!.widthEmu, 25400);

    final s = shapes.firstWhere((s) => s.text == 'Styled');
    expect(s.fillStyle!.color!.hex, '4F81BD');
    expect(s.line, isNotNull);
    expect(s.paragraphs.first.runs.first.color, 'FFFFFF');

    // The group doubles its children's size and moves them to (1000, 1000);
    // bg1 is remapped to the theme's dark colour on this slide.
    final inGroup = shapes.firstWhere((s) => s.inGroup);
    expect([inGroup.rect!.x, inGroup.rect!.y, inGroup.rect!.width, inGroup.rect!.height], [1200, 1400, 600, 800]);
    expect(inGroup.fill, '000000');
  });

  test('tables take their colours from the default table style', () {
    final deck = patched(edits: {'ppt/slides/slide1.xml': slideShapes(tableXml())});
    final shape = PptxReader.read(deck).slides.first.shapes.firstWhere((s) => s.table != null);
    final t = shape.table!;
    expect(shape.rect!.x, 500);
    expect(t.columns, [1000, 1000]);
    final header = t.rows[0].cells[0];
    expect(header.fill!.color!.hex, '4F81BD');
    expect(header.paragraphs.first.runs.first.color, 'FFFFFF');
    expect(header.paragraphs.first.runs.first.bold, isTrue);
    expect(header.bottom!.widthEmu, 38100);
    final body = t.rows[1].cells;
    expect(body[0].columnSpan, 2);
    expect(body[1].merged, isTrue);
    // The first data row takes the first band's lighter accent.
    expect(body[0].fill!.color!.hex, isNot('4F81BD'));
  });

  test('preset and freeform outlines', () {
    final ellipse = const PptxGeometry.preset('ellipse').paths(100, 50).single;
    expect(ellipse.ops.first, isA<MoveTo>());
    expect((ellipse.ops.first as MoveTo).x, 100);
    final arrow = const PptxGeometry.preset('rightArrow').paths(100, 50).single.ops.whereType<LineTo>().map((o) => o.x).reduce((a, b) => a > b ? a : b);
    expect(arrow, 100);
    final line = const PptxGeometry.preset('straightConnector1');
    expect(line.isLine, isTrue);
    expect(line.paths(10, 10).single.fill, isFalse);

    final cust = PptxGeometry.read(XmlDocument.parse('<a:spPr $_a><a:custGeom><a:pathLst><a:path w="10" h="10">'
        '<a:moveTo><a:pt x="0" y="0"/></a:moveTo><a:lnTo><a:pt x="10" y="0"/></a:lnTo>'
        '<a:arcTo wR="5" hR="5" stAng="16200000" swAng="10800000"/><a:close/></a:path></a:pathLst></a:custGeom></a:spPr>').rootElement)!;
    final ops = cust.paths(100, 100).single.ops;
    expect((ops[1] as LineTo).x, 100);
    // Half a circle from the top right corner ends 100 lower.
    final end = ops.whereType<CubicTo>().last;
    expect(end.x, closeTo(100, 0.001));
    expect(end.y, closeTo(100, 0.001));
    // Formulas are not worked out: such paths are left out.
    expect(PptxGeometry.read(XmlDocument.parse('<a:spPr $_a><a:custGeom><a:pathLst><a:path w="10" h="10">'
        '<a:moveTo><a:pt x="l" y="t"/></a:moveTo></a:path></a:pathLst></a:custGeom></a:spPr>').rootElement), isNull);
  });

  testWidgets('slides draw gradients, outlines, tables and master graphics without errors', (tester) async {
    final star = rectSp(20, '<a:prstGeom prst="star5"><a:avLst/></a:prstGeom><a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs>'
        '<a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs></a:gsLst><a:path path="circle"/></a:gradFill>');
    final shapes = '$star'
        '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="22" name="Arrow"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr><a:xfrm flipH="1"><a:off x="0" y="0"/><a:ext cx="5000" cy="0"/></a:xfrm>'
            '<a:prstGeom prst="straightConnector1"><a:avLst/></a:prstGeom><a:ln w="12700"><a:solidFill><a:srgbClr val="000000"/></a:solidFill><a:tailEnd type="triangle"/></a:ln></p:spPr></p:cxnSp>';
    final pres = PptxReader.read(patched(edits: {'ppt/slides/slide1.xml': slideShapes(shapes)}));
    expect(pres.slides.first.shapes.where((s) => s.geometry?.isLine ?? false), hasLength(1));
    await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 400, child: SlideCanvas(presentation: pres, slide: pres.slides.first)))));
    expect(tester.takeException(), isNull);
    expect(find.byType(ShapeFill), findsWidgets);
  });

  test('PDF export draws the recoloured background, shapes and tables', () async {
    final star = rectSp(20, '<a:prstGeom prst="star5"><a:avLst/></a:prstGeom><a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs>'
        '<a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs></a:gsLst><a:lin ang="5400000"/></a:gradFill>', text: 'Star');
    final arrow = '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="22" name="Arrow"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr><a:xfrm rot="5400000"><a:off x="0" y="0"/><a:ext cx="5000" cy="0"/></a:xfrm>'
        '<a:prstGeom prst="straightConnector1"><a:avLst/></a:prstGeom><a:ln w="12700"><a:solidFill><a:srgbClr val="000000"/></a:solidFill><a:tailEnd type="triangle"/></a:ln></p:spPr></p:cxnSp>';
    // Big enough for their words to fit.
    final bigStar = star.replaceFirst('cx="3000" cy="4000"', 'cx="2000000" cy="1500000"');
    final bigTable = tableXml().replaceFirst('cx="2000" cy="800"', 'cx="3000000" cy="800000"').replaceAll('w="1000"', 'w="1500000"').replaceAll('h="400"', 'h="400000"');
    final pres = PptxReader.read(duotoneDeck(more: {'ppt/slides/slide1.xml': slideShapes('$bigStar$arrow$bigTable')}));
    final pdf = await pptxToPdf(pres, testFonts());
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    final pdfium = Platform.environment['PDFIUM_PATH'];
    if (pdfium == null) return;
    Pdfrx.pdfiumModulePath = pdfium;
    final doc = await PdfDocument.openData(pdf);
    final page = doc.pages.first;
    final w = page.width.round(), h = page.height.round();
    final image = (await page.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), width: w, height: h, backgroundColor: 0xFFFFFFFF))!;
    final px = image.pixels;
    final text = (await page.loadStructuredText()).fullText;
    await doc.dispose();
    // BGRA. The grey texture comes out in the warm tone, not grey or white.
    final i = ((h - 5) * w + (w - 5)) * 4;
    final (b, g, r) = (px[i], px[i + 1], px[i + 2]);
    expect(r, greaterThan(g + 20));
    expect(g, greaterThan(b + 20));
    expect(text, contains('Star'));
    expect(text, contains('Both'));
  });
}

void edgeCases() {
  test('odd numbers in outlines and tables do not break drawing', () async {
    final arc = PptxGeometry.read(XmlDocument.parse('<p:spPr xmlns:p="p" $_a><a:custGeom><a:pathLst><a:path w="10" h="10"><a:moveTo><a:pt x="0" y="0"/></a:moveTo>'
            '<a:arcTo wR="5" hR="5" stAng="0" swAng="NaN"/></a:path></a:pathLst></a:custGeom></p:spPr>').rootElement);
    expect(arc, isNull);
    final huge = PptxGeometry.read(XmlDocument.parse('<p:spPr xmlns:p="p" $_a><a:custGeom><a:pathLst><a:path w="10" h="10"><a:moveTo><a:pt x="0" y="0"/></a:moveTo>'
            '<a:arcTo wR="5" hR="5" stAng="0" swAng="999999999999"/></a:path></a:pathLst></a:custGeom></p:spPr>').rootElement)!;
    expect(huge.paths(10, 10).first.ops.length, lessThan(10));
    final table = tableXml().replaceFirst('<a:tc gridSpan="2">', '<a:tc gridSpan="-1" rowSpan="0">');
    final pres = PptxReader.read(patched(edits: {'ppt/slides/slide1.xml': slideShapes(table)}));
    final cell = pres.slides.first.shapes.firstWhere((s) => s.table != null).table!.rows[1].cells.first;
    expect((cell.columnSpan, cell.rowSpan), (1, 1));
    expect(String.fromCharCodes((await pptxToPdf(pres, testFonts())).take(5)), '%PDF-');
  });

  test('grey pictures take on their new colours in the PDF', () {
    final grey = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4, numChannels: 1)..clear(img.ColorUint8.rgb(128, 128, 128))));
    // Everything becomes pure red.
    const red = <double>[0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0];
    final provider = PptxPdfImages().of(PptxFill.picture(grey, colorMatrix: red), 10, 10) as pw.MemoryImage;
    final out = img.decodeImage(provider.bytes)!;
    final p = out.getPixel(1, 1);
    expect(p.r, greaterThan(245));
    expect(p.g + p.b, lessThan(15));
  });

  test('shapes inside alternate content show but cannot be edited', () {
    final alt = '<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice Requires="p14">'
        '${rectSp(60, '', text: 'Choice')}</mc:Choice><mc:Fallback>${rectSp(61, '', text: 'Fallback')}</mc:Fallback></mc:AlternateContent>';
    final elements = <List<XmlElement>>[];
    final pres = PptxReader.readFrom(OoxmlPackage(patched(edits: {'ppt/slides/slide1.xml': slideShapes(alt)})), slideParts: <String>[], shapeElements: elements);
    final shape = pres.slides.first.shapes.firstWhere((s) => s.text == 'Fallback');
    expect(shape.ref, isNull);
    expect(elements.first, hasLength(2));
  });
}
