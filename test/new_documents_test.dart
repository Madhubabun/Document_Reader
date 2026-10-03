import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:doc_reader/services/new_documents.dart';
import 'package:doc_reader/services/ooxml/docx_editor.dart';
import 'package:doc_reader/services/ooxml/docx_reader.dart';
import 'package:doc_reader/services/ooxml/pptx_editor.dart';
import 'package:doc_reader/services/ooxml/pptx_reader.dart';
import 'package:doc_reader/services/ooxml/xlsx_editor.dart';
import 'package:doc_reader/services/ooxml/xlsx_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// Writes new files to $NEW_OUT so they can be opened in Office.
void keep(String name, List<int> bytes) {
  final dir = Platform.environment['NEW_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

NewTemplate template(NewKind kind, String name) => newTemplates.firstWhere((t) => t.kind == kind && t.name == name);

void main() {
  test('every template builds a well-formed package', () async {
    for (final t in newTemplates) {
      final bytes = await t.build('My ${t.name}');
      keep('${t.kind.name}-${t.name}.${t.kind.extension}', bytes);
      if (t.kind == NewKind.pdf) {
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-', reason: t.name);
        continue;
      }
      final zip = ZipDecoder().decodeBytes(bytes);
      final types = XmlDocument.parse(utf8.decode(zip.findFile('[Content_Types].xml')!.content as List<int>));
      final overrides = {for (final o in types.findAllElements('Override')) o.getAttribute('PartName')!.substring(1)};
      for (final f in zip.files) {
        if (!f.isFile) continue;
        if (f.name.endsWith('.xml') || f.name.endsWith('.rels')) {
          // Every XML part parses and every main part has a content type.
          XmlDocument.parse(utf8.decode(f.content as List<int>));
          if (f.name.endsWith('.xml') && f.name != '[Content_Types].xml') expect(overrides, contains(f.name), reason: '${t.name}: ${f.name}');
        }
        if (f.name.endsWith('.rels')) {
          // Every relationship points at a part in the package.
          final dir = f.name.replaceFirst(RegExp(r'_rels/[^/]+$'), '');
          for (final r in XmlDocument.parse(utf8.decode(f.content as List<int>)).findAllElements('Relationship')) {
            final target = Uri.parse('/$dir').resolve(r.getAttribute('Target')!).path.substring(1);
            expect(zip.findFile(target), isNotNull, reason: '${t.name}: ${f.name} -> $target');
          }
        }
      }
      expect(utf8.decode(zip.findFile('docProps/core.xml')!.content as List<int>), contains('<dc:title>My ${t.name}</dc:title>'));
    }
  });

  test('Word templates read back and can be edited', () async {
    final resume = DocxReader.read(await template(NewKind.word, 'Resume').build('CV'));
    final title = resume.blocks.whereType<DocxParagraph>().first;
    expect(title.isTitle, isTrue);
    expect(resume.blocks.whereType<DocxParagraph>().where((p) => p.headingLevel == 1).map((p) => p.text), ['Summary', 'Experience', 'Education', 'Skills']);

    final notes = DocxReader.read(await template(NewKind.word, 'Meeting notes').build('Notes'));
    expect(notes.blocks.whereType<DocxTable>().single.rows.first, ['Action', 'Owner', 'Due']);

    final blank = await template(NewKind.word, 'Blank').build('Blank');
    final editor = DocxEditor.open(blank);
    final p = editor.document.blocks.whereType<DocxParagraph>().single;
    editor.setParagraphText(p.ref!, 'Hello');
    expect(DocxReader.read(editor.save()).blocks.whereType<DocxParagraph>().single.text, 'Hello');
  });

  test('Excel templates have working formulas and styles', () async {
    final budget = XlsxReader.read(await template(NewKind.excel, 'Budget').build('Budget')).sheets.single;
    expect(budget.name, 'Budget');
    // Row 12 (index 11) totals income minus expenses: 3200-2500 planned, 3150-2570 actual.
    expect(budget.cell(11, 2)!.number, 700);
    expect(budget.cell(11, 3)!.number, 580);
    expect(budget.cell(11, 4)!.number, -120);
    expect(budget.cell(6, 4)!.number, 30); // groceries over by 30
    expect(budget.cell(6, 2)!.value, '400.00');
    expect(budget.cell(2, 0)!.style.bold, isTrue);
    expect(budget.cell(2, 0)!.style.fill, isNotNull);

    final invoice = XlsxReader.read(await template(NewKind.excel, 'Invoice').build('Invoice')).sheets.single;
    final amounts = {for (var r = 9; r < 12; r++) r: invoice.cell(r, 3)!.number};
    expect(amounts.values, [500, 150, 25]);
    expect(invoice.cell(17, 3)!.number, 675); // subtotal
    expect(invoice.cell(18, 3)!.value, '10%');
    expect(invoice.cell(19, 3)!.number, 67.5);
    expect(invoice.cell(20, 3)!.number, 742.5);
    expect(invoice.cell(4, 3)!.value, '0001');
    expect(invoice.cell(5, 3)!.style.isDate, isTrue);

    // Typing a new item updates the totals.
    final editor = XlsxEditor.open(await template(NewKind.excel, 'Invoice').build('Invoice'));
    editor.setCell(0, 12, 0, 'Extra');
    editor.setCell(0, 12, 1, '2');
    editor.setCell(0, 12, 2, '10');
    final after = editor.workbook.sheets.single;
    expect(after.cell(12, 3)!.number, 20);
    expect(after.cell(20, 3)!.number, closeTo(764.5, 1e-9));

    final todo = XlsxReader.read(await template(NewKind.excel, 'To-do list').build('Todo')).sheets.single;
    expect(todo.columnWidths[3], 40);
    final blank = XlsxEditor.open(await template(NewKind.excel, 'Blank').build('Blank'));
    blank.setCell(0, 0, 0, '5');
    blank.setCell(0, 1, 0, '=A1*2');
    expect(blank.workbook.sheets.single.cell(1, 0)!.number, 10);
  });

  test('PowerPoint templates use real layouts and placeholders', () async {
    final bytes = await template(NewKind.powerpoint, 'Project update').build('Update');
    final pres = PptxReader.read(bytes);
    expect(pres.slides, hasLength(5));
    expect(pres.slideWidth / pres.slideHeight, closeTo(16 / 9, 0.01));
    expect(pres.slides.first.title, 'Project update');
    final body = pres.slides[1].shapes.firstWhere((s) => s.kind == PptxShapeKind.body);
    expect(body.paragraphs.map((p) => p.text), ['What we set out to do', 'How we measure success']);
    expect(body.paragraphs.every((p) => p.bullet), isTrue);
    // Placeholders inherit their place from the layout or master.
    expect(body.rect, isNotNull);
    expect(pres.slides.first.shapes.every((s) => s.rect != null), isTrue);

    // A slide added after the title slide gets the Title and Content layout.
    final editor = PptxEditor.open(await template(NewKind.powerpoint, 'Blank').build('Deck'));
    final title = editor.presentation.slides.single.shapes.firstWhere((s) => s.kind == PptxShapeKind.title);
    editor.setShapeText(0, title.ref!, 'My talk');
    final added = editor.addSlide(0);
    final saved = editor.save();
    final zip = ZipDecoder().decodeBytes(saved);
    final rels = utf8.decode(zip.findFile('ppt/slides/_rels/slide2.xml.rels')!.content as List<int>);
    expect(rels, contains('slideLayout2.xml'));
    final again = PptxReader.read(saved);
    expect(again.slides, hasLength(2));
    expect(again.slides[0].title, 'My talk');
    final reopened = PptxEditor.open(saved);
    final kinds = reopened.presentation.slides[added].shapes.map((s) => s.kind).toSet();
    expect(kinds, containsAll([PptxShapeKind.title, PptxShapeKind.body]));
    keep('added-slide.pptx', saved);
  });
}
