import 'dart:io';

import 'package:archive/archive.dart';
import 'package:doc_reader/services/ooxml/docx_reader.dart';
import 'package:doc_reader/services/ooxml/pptx_reader.dart';
import 'package:doc_reader/services/ooxml/xlsx_reader.dart';
import 'package:doc_reader/services/ooxml/xml_utils.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

List<int> zip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) => archive.addFile(ArchiveFile.string(name, content)));
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  group('DocxReader', () {
    late DocxDocument doc;
    setUpAll(() => doc = DocxReader.read(fixture('sample.docx')));

    List<DocxParagraph> paragraphs() => doc.blocks.whereType<DocxParagraph>().toList();

    test('reads title and headings', () {
      final title = paragraphs().firstWhere((p) => p.isTitle);
      expect(title.text, 'Project Brief');
      final h1 = paragraphs().firstWhere((p) => p.headingLevel == 1);
      expect(h1.text, 'Objectives');
    });

    test('keeps run formatting', () {
      final p = paragraphs().firstWhere((p) => p.text.startsWith('Plain start'));
      expect(p.runs.map((r) => r.text), ['Plain start, ', 'bold part', ' and italic red']);
      expect(p.runs[1].bold, isTrue);
      expect(p.runs[0].bold, isFalse);
      expect(p.runs[2].italic, isTrue);
      expect(p.runs[2].color, 'C00000');
      expect(p.runs[2].fontSizePt, 14);
    });

    test('detects list items and alignment', () {
      final bullets = paragraphs().where((p) => p.listLevel != null).map((p) => p.text);
      expect(bullets, ['First bullet', 'Second bullet']);
      expect(paragraphs().firstWhere((p) => p.text == 'Centered line').align, ParagraphAlign.center);
    });

    test('reads tables and images', () {
      final table = doc.blocks.whereType<DocxTable>().single;
      expect(table.rows, [
        ['Phase', 'Weeks'],
        ['Survey', '1-2'],
      ]);
      final image = doc.blocks.whereType<DocxImage>().single;
      expect(image.bytes.take(4), [0x89, 0x50, 0x4E, 0x47]);
      expect(image.widthEmu, 914400);
    });

    test('plain text includes body and table', () {
      expect(doc.plainText, contains('bold part'));
      expect(doc.plainText, contains('Survey\t1-2'));
    });

    test('w:b w:val="0" turns bold off', () {
      final bytes = zip({
        'word/document.xml': '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
            '<w:p><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>not bold</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r></w:p>'
            '</w:body></w:document>',
      });
      final runs = (DocxReader.read(bytes).blocks.single as DocxParagraph).runs;
      expect(runs[0].bold, isFalse);
      expect(runs[1].bold, isTrue);
    });

    test('rejects files that are not Word documents', () {
      expect(() => DocxReader.read(zip({'hello.txt': 'hi'})), throwsA(isA<OoxmlFormatException>()));
    });
  });

  group('XlsxReader', () {
    late XlsxWorkbook book;
    setUpAll(() => book = XlsxReader.read(fixture('sample.xlsx')));

    test('reads sheet names in order', () {
      expect(book.sheets.map((s) => s.name), ['Budget', 'Notes']);
    });

    test('resolves shared strings, numbers, booleans and formulas', () {
      final s = book.sheets.first;
      expect(s.cell(0, 0)?.value, 'Item');
      expect(s.cell(1, 0)?.value, 'Laptop');
      expect(s.cell(1, 1)?.value, '1200');
      expect(s.cell(1, 1)?.isNumber, isTrue);
      expect(s.cell(2, 1)?.value, '0.3');
      expect(s.cell(3, 1)?.formula, 'SUM(B2:B3)');
      expect(s.cell(9, 3)?.value, 'TRUE');
      expect(s.rowCount, 10);
      expect(s.columnCount, 4);
    });

    test('second sheet', () {
      expect(book.sheets[1].cell(0, 0)?.value, 'Shared string again: Laptop');
    });

    test('column helpers round-trip', () {
      for (final (name, index) in [('A', 0), ('Z', 25), ('AA', 26), ('AZ', 51), ('XFD', 16383)]) {
        expect(XlsxReader.columnIndex(name), index);
        expect(XlsxReader.columnName(index), name);
      }
      expect(XlsxReader.parseCellRef(r'$C$7'), (6, 2));
    });
  });

  group('PptxReader', () {
    late PptxPresentation deck;
    setUpAll(() => deck = PptxReader.read(fixture('sample.pptx')));

    test('reads slide size and slide order', () {
      expect(deck.slideWidth, 12192000);
      expect(deck.slideHeight, 6858000);
      expect(deck.aspectRatio, closeTo(16 / 9, 0.01));
      expect(deck.slides.map((s) => s.title), ['Q3 Highlights', 'Results']);
    });

    test('reads body bullets with levels', () {
      final body = deck.slides[1].shapes.firstWhere((s) => s.kind == PptxShapeKind.body);
      expect(body.paragraphs.map((p) => p.text), ['Revenue up', 'New markets']);
      expect(body.paragraphs[1].level, 1);
      expect(body.paragraphs.first.bullet, isTrue);
    });

    test('placeholders inherit their position from the slide layout', () {
      final title = deck.slides[0].shapes.firstWhere((s) => s.kind == PptxShapeKind.title);
      expect(title.rect, isNotNull);
      expect(title.rect!.width, greaterThan(deck.slideWidth ~/ 2));
      final subtitle = deck.slides[0].shapes.firstWhere((s) => s.kind == PptxShapeKind.body);
      expect(subtitle.rect!.y, greaterThan(title.rect!.y));
    });

    test('reads pictures with position and text boxes', () {
      final pic = deck.slides[1].shapes.firstWhere((s) => s.kind == PptxShapeKind.picture);
      expect(pic.imageBytes, isNotNull);
      expect(pic.rect?.x, 9 * 914400);
      final box = deck.slides[1].shapes.firstWhere((s) => s.kind == PptxShapeKind.text);
      expect(box.paragraphs.single.runs.single.bold, isTrue);
      expect(box.paragraphs.single.runs.single.fontSizePt, 12);
    });
  });

  test('relationship targets resolve relative paths', () {
    expect(OoxmlPackage.resolvePath('ppt/slides', '../media/image1.png'), 'ppt/media/image1.png');
    expect(OoxmlPackage.resolvePath('word', 'media/a.png'), 'word/media/a.png');
    expect(OoxmlPackage.resolvePath('xl', '/xl/worksheets/sheet1.xml'), 'xl/worksheets/sheet1.xml');
  });
}
