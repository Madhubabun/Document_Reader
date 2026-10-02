import 'dart:io';
import 'dart:typed_data';

import 'package:doc_reader/services/convert/converter.dart';
import 'package:doc_reader/services/convert/office_to_pdf.dart';
import 'package:doc_reader/services/convert/pdf_to_office.dart';
import 'package:doc_reader/services/ooxml/docx_reader.dart';
import 'package:doc_reader/services/ooxml/docx_writer.dart';
import 'package:doc_reader/services/ooxml/pptx_reader.dart';
import 'package:doc_reader/services/ooxml/pptx_writer.dart';
import 'package:doc_reader/services/ooxml/xlsx_reader.dart';
import 'package:doc_reader/services/ooxml/xlsx_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

OfficeFonts testFonts() {
  ByteData f(String name) => ByteData.sublistView(File('assets/fonts/office/Carlito-$name.ttf').readAsBytesSync());
  return OfficeFonts(regular: f('normal-400'), bold: f('normal-700'), italic: f('italic-400'), boldItalic: f('italic-700'));
}

/// Set PDFIUM_PATH to a libpdfium build to run the PDF -> Office tests.
final pdfium = Platform.environment['PDFIUM_PATH'];

/// Set CONVERT_OUT to a folder to keep the generated files for inspection.
void keep(String name, List<int> bytes) {
  final dir = Platform.environment['CONVERT_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

void main() {
  group('OOXML writers round-trip through the readers', () {
    test('docx keeps headings, formatting, tables, images and page setup', () {
      final original = DocxReader.read(fixture('sample.docx'));
      final bytes = DocxWriter.write(original, title: 'Sample');
      keep('roundtrip.docx', bytes);
      final again = DocxReader.read(bytes);
      expect(again.plainText, original.plainText);
      final paras = again.blocks.whereType<DocxParagraph>();
      expect(paras.firstWhere((p) => p.isTitle).text, 'Project Brief');
      expect(paras.firstWhere((p) => p.headingLevel == 1).text, 'Objectives');
      final styled = paras.firstWhere((p) => p.text.startsWith('Plain start'));
      expect(styled.runs[1].bold, isTrue);
      expect(styled.runs[2].color, 'C00000');
      expect(styled.runs[2].fontSizePt, 14);
      expect(again.blocks.whereType<DocxTable>().length, original.blocks.whereType<DocxTable>().length);
      expect(again.blocks.whereType<DocxImage>().length, original.blocks.whereType<DocxImage>().length);
      expect(again.page.width, original.page.width);
    });

    test('xlsx keeps values, numbers and formulas', () {
      final original = XlsxReader.read(fixture('sample.xlsx'));
      final bytes = XlsxWriter.write(original, title: 'Sample');
      keep('roundtrip.xlsx', bytes);
      final again = XlsxReader.read(bytes);
      expect(again.sheets.map((s) => s.name), original.sheets.map((s) => s.name));
      for (var i = 0; i < original.sheets.length; i++) {
        original.sheets[i].cells.forEach((key, cell) {
          final copy = again.sheets[i].cells[key];
          expect(copy?.value, cell.value, reason: 'cell $key');
          expect(copy?.formula, cell.formula, reason: 'cell $key');
          expect(copy?.isNumber, cell.isNumber, reason: 'cell $key');
        });
      }
    });

    test('pptx keeps slide size, text and pictures', () {
      final original = PptxReader.read(fixture('sample.pptx'));
      final bytes = PptxWriter.write(original, title: 'Sample');
      keep('roundtrip.pptx', bytes);
      final again = PptxReader.read(bytes);
      expect(again.slideWidth, original.slideWidth);
      expect(again.slides.length, original.slides.length);
      for (var i = 0; i < original.slides.length; i++) {
        final text = original.slides[i].shapes.map((s) => s.text).where((t) => t.trim().isNotEmpty).toList();
        final copied = again.slides[i].shapes.map((s) => s.text).where((t) => t.trim().isNotEmpty).toList();
        expect(copied, text);
        expect(again.slides[i].shapes.where((s) => s.imageBytes != null).length,
            original.slides[i].shapes.where((s) => s.imageBytes != null).length);
      }
    });

    test('sheet names follow Excel rules', () {
      final taken = <String>{};
      expect(XlsxWriter.uniqueSheetName('Q1/Q2: [draft]', taken), 'Q1 Q2   draft');
      expect(XlsxWriter.uniqueSheetName('Data', taken), 'Data');
      expect(XlsxWriter.uniqueSheetName('data', taken), 'data (2)');
      expect(XlsxWriter.uniqueSheetName('x' * 40, taken).length, 31);
    });
  });

  group('Office to PDF', () {
    final fonts = testFonts();
    for (final (name, convert) in [
      ('sample.docx', () => docxToPdf(DocxReader.read(fixture('sample.docx')), fonts)),
      ('sample.xlsx', () => xlsxToPdf(XlsxReader.read(fixture('sample.xlsx')), fonts)),
      ('sample.pptx', () => pptxToPdf(PptxReader.read(fixture('sample.pptx')), fonts)),
    ]) {
      test('$name makes a valid PDF', () async {
        final pdf = await convert();
        keep('$name.pdf', pdf);
        expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
        if (pdfium == null) return;
        Pdfrx.pdfiumModulePath = pdfium;
        final doc = await PdfDocument.openData(pdf);
        expect(doc.pages, isNotEmpty);
        final text = await doc.pages.first.loadStructuredText();
        expect(text.fullText.trim(), isNotEmpty);
        await doc.dispose();
      });
    }

    test('PowerPoint pages use the slide size', () async {
      final pres = PptxReader.read(fixture('sample.pptx'));
      final pdf = await pptxToPdf(pres, fonts);
      if (pdfium == null) return;
      Pdfrx.pdfiumModulePath = pdfium;
      final doc = await PdfDocument.openData(pdf);
      expect(doc.pages.length, pres.slides.length);
      expect(doc.pages.first.width, closeTo(pres.slideWidth / 12700, 0.5));
      await doc.dispose();
    });
  });

  group('PDF text layout', () {
    test('words on one baseline join into a line, wide gaps split columns', () {
      final lines = groupLinesFrom([
        ('Item', 50, 100, 70, 110),
        ('Price', 300, 100, 325, 110),
        ('Green', 50, 115, 75, 125),
        ('apples', 78, 115, 105, 125),
        ('1,250.50', 300, 115, 340, 125),
      ]);
      expect(lines.length, 2);
      expect(lines[0].segments.map((s) => s.text), ['Item', 'Price']);
      expect(lines[1].segments.map((s) => s.text), ['Green apples', '1,250.50']);
    });

    test('lines merge into paragraphs and big lines become headings', () {
      final lines = groupLinesFrom([
        ('Annual', 72, 60, 160, 84),
        ('Report', 165, 60, 250, 84),
        ('This', 72, 100, 92, 111),
        ('is', 95, 100, 103, 111),
        ('one', 72, 113, 90, 124),
        ('para-', 93, 113, 118, 124),
        ('graph.', 72, 126, 100, 137),
        ('•', 72, 160, 76, 171),
        ('First', 100, 160, 120, 171),
      ]);
      final doc = pdfContentToDocx([PdfPageContent(width: 612, height: 792, lines: lines)]);
      final paras = doc.blocks.whereType<DocxParagraph>().toList();
      expect(paras.map((p) => p.text), ['Annual Report', 'This is one paragraph.', 'First']);
      expect(paras[0].headingLevel, greaterThan(0));
      expect(paras[1].headingLevel, 0);
      expect(paras[2].listLevel, 0);
      expect(doc.page.width, 612 * 20);
    });

    test('table-like text becomes columns with real numbers', () {
      final lines = groupLinesFrom([
        ('Item', 50, 100, 70, 110),
        ('Price', 300, 100, 325, 110),
        ('Pens', 50, 115, 70, 125),
        ('1,250.50', 300, 115, 340, 125),
        ('Ink', 50, 130, 65, 140),
        ('(12)', 302, 130, 320, 140),
      ]);
      final book = pdfContentToXlsx([PdfPageContent(width: 612, height: 792, lines: lines)]);
      final sheet = book.sheets.single;
      expect(sheet.name, 'Page 1');
      expect(sheet.cell(0, 1)?.value, 'Price');
      expect(sheet.cell(1, 1)?.value, '1250.5');
      expect(sheet.cell(1, 1)?.isNumber, isTrue);
      expect(sheet.cell(2, 1)?.value, '-12');
    });
  });

  group('PDF to Office (needs PDFIUM_PATH)', () {
    late String pdfPath;
    setUpAll(() async {
      if (pdfium == null) return;
      Pdfrx.pdfiumModulePath = pdfium;
      final pdf = await docxToPdf(DocxReader.read(fixture('sample.docx')), testFonts());
      final dir = await Directory.systemTemp.createTemp('convert');
      pdfPath = '${dir.path}/Brief.pdf';
      await File(pdfPath).writeAsBytes(pdf);
    });

    Future<Uint8List> run(String ext) => convertFile(pdfPath, ext, fonts: () async => testFonts());

    test('to Word keeps the text', () async {
      final bytes = await run('docx');
      keep('fromPdf.docx', bytes);
      final doc = DocxReader.read(bytes);
      expect(doc.plainText, contains('Project Brief'));
      expect(doc.plainText, contains('Objectives'));
    }, skip: pdfium == null);

    test('to Excel makes a sheet per page', () async {
      final bytes = await run('xlsx');
      keep('fromPdf.xlsx', bytes);
      final book = XlsxReader.read(bytes);
      expect(book.sheets, isNotEmpty);
      expect(book.sheets.first.cells.values.map((c) => c.value).join(' '), contains('Project Brief'));
    }, skip: pdfium == null);

    test('to PowerPoint makes a picture slide per page', () async {
      final bytes = await run('pptx');
      keep('fromPdf.pptx', bytes);
      final pres = PptxReader.read(bytes);
      expect(pres.slides, isNotEmpty);
      expect(pres.slides.first.shapes.single.imageBytes, isNotNull);
    }, skip: pdfium == null);
  });
}
