import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../ooxml/docx_reader.dart';
import '../ooxml/pptx_reader.dart';
import '../ooxml/xlsx_reader.dart';
import 'pptx_pdf_shapes.dart';

/// Font files used when drawing Office content into a PDF. Carlito has the
/// same metrics as Calibri, so line breaks match Word closely.
class OfficeFonts {
  const OfficeFonts({required this.regular, required this.bold, required this.italic, required this.boldItalic});

  final ByteData regular;
  final ByteData bold;
  final ByteData italic;
  final ByteData boldItalic;

  pw.ThemeData theme() => pw.ThemeData.withFont(
        base: pw.Font.ttf(regular),
        bold: pw.Font.ttf(bold),
        italic: pw.Font.ttf(italic),
        boldItalic: pw.Font.ttf(boldItalic),
      );
}

const _maxPages = 2000;
const _ink = PdfColor.fromInt(0xFF1C1C22);
const _headingBlue = PdfColor.fromInt(0xFF2F5496);

PdfColor? _hex(String? hex) {
  if (hex == null || hex.length != 6) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : PdfColor.fromInt(0xFF000000 | v);
}

PdfColor? _highlight(String? name) => switch (name) {
      'yellow' => const PdfColor.fromInt(0xFFFFFF00),
      'green' => const PdfColor.fromInt(0xFF00FF00),
      'cyan' => const PdfColor.fromInt(0xFF00FFFF),
      'magenta' => const PdfColor.fromInt(0xFFFF00FF),
      'blue' => const PdfColor.fromInt(0xFF0000FF),
      'red' => const PdfColor.fromInt(0xFFFF0000),
      'lightGray' => const PdfColor.fromInt(0xFFD3D3D3),
      _ => null,
    };

/// Word -> PDF using the document's own page size and margins.
Future<Uint8List> docxToPdf(DocxDocument doc, OfficeFonts fonts) {
  final page = doc.page;
  const twip = 1 / 20; // points per twip
  final format = PdfPageFormat(
    page.width * twip,
    page.height * twip,
    marginTop: page.marginTop * twip,
    marginBottom: page.marginBottom * twip,
    marginLeft: page.marginLeft * twip,
    marginRight: page.marginRight * twip,
  );
  final contentWidth = format.availableWidth;
  final pdf = pw.Document(theme: fonts.theme(), title: '');

  final widgets = <pw.Widget>[];
  for (final block in doc.blocks) {
    switch (block) {
      case DocxPageBreak _:
        widgets.add(pw.NewPage());
      case DocxParagraph p:
        widgets.add(_paragraph(p));
      case DocxTable t:
        if (t.rows.isNotEmpty) {
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.TableHelper.fromTextArray(
              data: t.rows,
              headerCount: 0,
              cellStyle: const pw.TextStyle(fontSize: 10, color: _ink),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              border: pw.TableBorder.all(width: 0.5, color: const PdfColor.fromInt(0xFF000000)),
              cellAlignment: pw.Alignment.topLeft,
            ),
          ));
        }
      case DocxImage img:
        final w = img.widthEmu == null ? contentWidth : img.widthEmu! / 12700;
        final h = img.heightEmu == null ? null : img.heightEmu! / 12700;
        final scale = w > contentWidth ? contentWidth / w : 1.0;
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Image(pw.MemoryImage(img.bytes), width: w * scale, height: h == null ? null : h * scale, fit: pw.BoxFit.contain),
        ));
    }
  }
  if (widgets.isEmpty) widgets.add(pw.SizedBox());
  pdf.addPage(pw.MultiPage(pageFormat: format, maxPages: _maxPages, build: (_) => widgets));
  return pdf.save();
}

pw.Widget _paragraph(DocxParagraph p) {
  final isHeading = p.isTitle || p.headingLevel > 0;
  final base = p.isTitle
      ? 28.0
      : switch (p.headingLevel) {
          1 => 16.0,
          2 => 13.0,
          3 => 12.0,
          4 || 5 || 6 => 11.0,
          _ => 11.0,
        };
  final style = pw.TextStyle(
    fontSize: base,
    color: isHeading && !p.isTitle ? _headingBlue : _ink,
    lineSpacing: isHeading ? 1 : 2,
  );
  final spans = [
    for (final r in p.runs)
      pw.TextSpan(
        text: r.text.replaceAll('\t', '    '),
        style: pw.TextStyle(
          fontWeight: r.bold ? pw.FontWeight.bold : null,
          fontStyle: r.italic ? pw.FontStyle.italic : null,
          fontSize: r.fontSizePt,
          color: _hex(r.color),
          decoration: pw.TextDecoration.combine([
            if (r.underline) pw.TextDecoration.underline,
            if (r.strike) pw.TextDecoration.lineThrough,
          ]),
          background: _highlight(r.highlight) == null ? null : pw.BoxDecoration(color: _highlight(r.highlight)),
        ),
      ),
  ];
  if (spans.isEmpty) return pw.SizedBox(height: base * 1.2);
  final align = switch (p.align) {
    ParagraphAlign.center => pw.TextAlign.center,
    ParagraphAlign.right => pw.TextAlign.right,
    ParagraphAlign.justify => pw.TextAlign.justify,
    ParagraphAlign.left => pw.TextAlign.left,
  };
  final text = pw.SizedBox(
    width: double.infinity,
    child: pw.RichText(text: pw.TextSpan(style: style, children: spans), textAlign: align),
  );
  final padding = pw.EdgeInsets.only(top: isHeading ? (p.headingLevel == 1 ? 12 : 2) : 0, bottom: isHeading ? 2 : 8);
  if (p.listLevel == null) return pw.Padding(padding: padding, child: text);
  return pw.Padding(
    padding: padding.add(pw.EdgeInsets.only(left: 18.0 * p.listLevel!)),
    child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(width: 18, child: pw.Text('•', style: style)),
      pw.Expanded(child: text),
    ]),
  );
}

/// Excel -> PDF: one table per sheet, landscape when the sheet is wide.
Future<Uint8List> xlsxToPdf(XlsxWorkbook book, OfficeFonts fonts) {
  final pdf = pw.Document(theme: fonts.theme());
  for (final sheet in book.sheets) {
    final cols = sheet.columnCount;
        final format = (cols > 6 ? PdfPageFormat.a4.landscape : PdfPageFormat.a4).copyWith(
      marginLeft: 36,
      marginRight: 36,
      marginTop: 36,
      marginBottom: 36,
    );
    String show(XlsxCell? cell) {
      if (cell == null) return '';
      if (cell.value.isEmpty && cell.formula != null) return '=${cell.formula}';
      return cell.value;
    }

    final usedRows = {for (final key in sheet.cells.keys) key.$1}.toList()..sort();
    final data = [
      for (final r in usedRows) [for (var c = 0; c < cols; c++) show(sheet.cell(r, c))],
    ];
    final fontSize = cols > 14 ? 6.5 : (cols > 8 ? 8.0 : 10.0);
    pdf.addPage(pw.MultiPage(
      pageFormat: format,
      maxPages: _maxPages,
      header: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Text(sheet.name, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink)),
      ),
      build: (_) => [
        if (data.isEmpty)
          pw.Text('(empty sheet)')
        else
          pw.TableHelper.fromTextArray(
            data: data,
            headerCount: 0,
            cellStyle: pw.TextStyle(fontSize: fontSize, color: _ink),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            border: pw.TableBorder.all(width: 0.4, color: const PdfColor.fromInt(0xFFBFBFBF)),
            cellAlignments: {
              for (var c = 0; c < cols; c++)
                c: (sheet.cells.entries.where((e) => e.key.$2 == c).every((e) => e.value.isNumber || e.value.value.isEmpty) &&
                        sheet.cells.keys.any((k) => k.$2 == c))
                    ? pw.Alignment.centerRight
                    : pw.Alignment.centerLeft,
            },
          ),
      ],
    ));
  }
  if (book.sheets.isEmpty) pdf.addPage(pw.Page(build: (_) => pw.SizedBox()));
  return pdf.save();
}

/// PowerPoint -> PDF: one page per slide at the deck's exact size.
Future<Uint8List> pptxToPdf(PptxPresentation pres, OfficeFonts fonts) {
  const emuPerPt = 12700.0;
  final pageW = pres.slideWidth / emuPerPt;
  final pageH = pres.slideHeight / emuPerPt;
  final pdf = pw.Document(theme: fonts.theme());
  final images = PptxPdfImages();
  for (final slide in pres.slides) {
    var autoTop = 0.08;
    final children = <pw.Widget>[];
    for (final shape in slide.shapes) {
      var rect = shape.rect;
      if (rect == null) {
        final isTitle = shape.kind == PptxShapeKind.title;
        rect = EmuRect((pres.slideWidth * 0.07).round(), (pres.slideHeight * (isTitle ? 0.06 : autoTop)).round(),
            (pres.slideWidth * 0.86).round(), (pres.slideHeight * (isTitle ? 0.18 : 0.62)).round());
        autoTop = isTitle ? 0.28 : autoTop + 0.62;
      }
      final left = rect.x / emuPerPt;
      final top = rect.y / emuPerPt;
      final width = math.max(0.0, rect.width / emuPerPt);
      final height = math.max(0.0, rect.height / emuPerPt);
      final defaultPt = switch (shape.kind) {
        PptxShapeKind.title => 40.0,
        PptxShapeKind.body => 24.0,
        _ => 18.0,
      };
      final table = shape.table;
      pw.Widget child;
      if (table != null) {
        child = _pptxTable(table, images);
      } else {
        final fill = shape.kind == PptxShapeKind.picture && shape.imageBytes != null
            ? shape.fillStyle ?? PptxFill.picture(shape.imageBytes!)
            : shape.fillStyle ?? (shape.fill == null ? null : PptxFill.solid(PptxColor(shape.fill!)));
        child = PptxPdfShape(
          width: width,
          height: height,
          images: images,
          fill: fill,
          line: shape.line,
          geometry: shape.geometry,
          flipH: shape.flipH,
          flipV: shape.flipV,
        );
        if (shape.kind != PptxShapeKind.picture && shape.paragraphs.any((p) => p.text.trim().isNotEmpty)) {
          child = pw.Stack(children: [
            child,
            _pptxText(shape.paragraphs, shape.kind, shape.anchor, width, height, defaultPt, const pw.EdgeInsets.all(7.2)),
          ]);
        }
      }
      // PowerPoint turns shapes clockwise; PDF angles go the other way.
      if (shape.rotation != 0) child = pw.Transform.rotate(angle: -shape.rotation * math.pi / 180, child: child);
      children.add(pw.Positioned(left: left, top: top, child: child));
    }
    final background = slide.backgroundFill ??
        (slide.backgroundImage != null
            ? PptxFill.picture(slide.backgroundImage!)
            : PptxFill.solid(PptxColor(slide.background ?? 'FFFFFF')));
    pdf.addPage(pw.Page(
      pageFormat: PdfPageFormat(pageW, pageH),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.SizedBox(
        width: pageW,
        height: pageH,
        child: pw.Stack(overflow: pw.Overflow.clip, children: [
          // White under see-through or missing backgrounds, like PowerPoint.
          PptxPdfShape(width: pageW, height: pageH, images: images, fill: const PptxFill.solid(PptxColor('FFFFFF'))),
          PptxPdfShape(width: pageW, height: pageH, images: images, fill: background),
          ...children,
        ]),
      ),
    ));
  }
  if (pres.slides.isEmpty) pdf.addPage(pw.Page(pageFormat: PdfPageFormat(pageW, pageH), build: (_) => pw.SizedBox()));
  return pdf.save();
}

/// A table with each cell placed on the grid, so merged cells can span.
pw.Widget _pptxTable(PptxTable table, PptxPdfImages images) {
  const emuPerPt = 12700.0;
  final xs = [0.0];
  for (final w in table.columns) {
    xs.add(xs.last + w / emuPerPt);
  }
  final ys = [0.0];
  for (final r in table.rows) {
    ys.add(ys.last + r.height / emuPerPt);
  }
  pw.BorderSide side(PptxLine? l) =>
      l == null ? pw.BorderSide.none : pw.BorderSide(color: pdfColor(l.color), width: math.max(0.25, l.widthEmu / emuPerPt));
  final cells = <pw.Widget>[];
  for (var r = 0; r < table.rows.length; r++) {
    var col = 0;
    for (final cell in table.rows[r].cells) {
      final c = col;
      col++;
      if (cell.merged || c >= table.columns.length) continue;
      final right = math.min(c + cell.columnSpan, table.columns.length);
      final bottom = math.min(r + cell.rowSpan, table.rows.length);
      final w = xs[right] - xs[c];
      final h = ys[bottom] - ys[r];
      cells.add(pw.Positioned(
        left: xs[c],
        top: ys[r],
        child: pw.Stack(children: [
          PptxPdfShape(width: w, height: h, images: images, fill: cell.fill),
          pw.Container(
            width: w,
            height: h,
            decoration: pw.BoxDecoration(border: pw.Border(left: side(cell.left), right: side(cell.right), top: side(cell.top), bottom: side(cell.bottom))),
          ),
          _pptxText(cell.paragraphs, PptxShapeKind.text, cell.anchor, w, h, 18, const pw.EdgeInsets.symmetric(horizontal: 7.2, vertical: 3.6)),
        ]),
      ));
    }
  }
  return pw.SizedBox(width: xs.last, height: ys.last, child: pw.Stack(overflow: pw.Overflow.visible, children: cells));
}

/// Slide text, shrunk if needed so it stays inside its box.
pw.Widget _pptxText(List<PptxParagraph> paragraphs, PptxShapeKind kind, String anchor, double width, double height, double defaultPt,
    pw.EdgeInsets padding) {
  if (paragraphs.every((p) => p.text.trim().isEmpty)) return pw.SizedBox(width: width, height: height);
  // Tiny boxes keep their text without the usual inset.
  if (width - padding.horizontal < 2 || height - padding.vertical < 2) padding = pw.EdgeInsets.zero;
  if (width < 2 || height < 2) return pw.SizedBox(width: width, height: height);
  final inner = width - padding.horizontal;
  return pw.Container(
    width: width,
    height: height,
    padding: padding,
    child: pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: switch (anchor) {
        'ctr' => pw.Alignment.centerLeft,
        'b' => pw.Alignment.bottomLeft,
        _ => pw.Alignment.topLeft,
      },
      child: pw.SizedBox(
        width: inner,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            for (final para in paragraphs)
              pw.Padding(
                padding: pw.EdgeInsets.only(left: para.level * 28.0),
                child: pw.RichText(
                  textAlign: switch (para.align) {
                    'ctr' => pw.TextAlign.center,
                    'r' => pw.TextAlign.right,
                    'just' => pw.TextAlign.justify,
                    _ => pw.TextAlign.left,
                  },
                  text: pw.TextSpan(
                    style: pw.TextStyle(fontSize: defaultPt, color: const PdfColor.fromInt(0xFF1F2937)),
                    children: [
                      if (para.bullet && para.text.trim().isNotEmpty) const pw.TextSpan(text: '•  '),
                      for (final run in para.runs)
                        pw.TextSpan(
                          text: run.text,
                          style: pw.TextStyle(
                            fontSize: run.fontSizePt,
                            fontWeight: run.bold || kind == PptxShapeKind.title ? pw.FontWeight.bold : null,
                            fontStyle: run.italic ? pw.FontStyle.italic : null,
                            color: _hex(run.color),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
