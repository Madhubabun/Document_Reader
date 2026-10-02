import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:doc_reader/services/ooxml/docx_editor.dart';
import 'package:doc_reader/services/ooxml/docx_reader.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

String part(List<int> docx, String name) => utf8.decode(ZipDecoder().decodeBytes(docx).findFile(name)!.content as List<int>);

/// Writes edited files to $DOCX_OUT so they can be opened in Word.
void keep(String name, List<int> bytes) {
  final dir = Platform.environment['DOCX_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

void main() {
  late DocxEditor editor;
  setUp(() => editor = DocxEditor.open(fixture('sample.docx')));

  List<DocxParagraph> paragraphs(DocxDocument d) => d.blocks.whereType<DocxParagraph>().toList();
  DocxParagraph para(int ref) => paragraphs(editor.document).firstWhere((p) => p.ref == ref);

  test('blocks carry refs back to the XML', () {
    expect(para(0).text, 'Project Brief');
    expect(para(2).runs.map((r) => r.text), ['Plain start, ', 'bold part', ' and italic red']);
    expect(editor.document.blocks.whereType<DocxTable>().single.ref, 0);
  });

  test('typing changes only the runs that hold the change', () {
    editor.setParagraphText(2, 'Plain start, very bold part and italic red');
    editor.setParagraphText(2, 'Plain start, very bold part and italic red!');
    final runs = para(2).runs;
    expect(runs.map((r) => r.text), ['Plain start, very ', 'bold part', ' and italic red!']);
    expect(runs[1].bold, isTrue);
    expect(runs[2].italic, isTrue);
    expect(runs[2].color, 'C00000');
    expect(editor.hasChanges, isTrue);
  });

  test('text typed at the end of a bold word stays bold, and deleting across runs works', () {
    editor.setParagraphText(2, 'Plain start, bold partly and italic red');
    expect(para(2).runs[1].text, 'bold partly');
    editor.setParagraphText(2, 'Plain red');
    expect(para(2).runs.map((r) => r.text), ['Plain ', 'red']);
    expect(para(2).runs[1].italic, isTrue);
  });

  test('tabs, line breaks and spaces are kept as Word elements', () {
    editor.setParagraphText(5, '  Centered\tline\nnext ');
    final xml = part(editor.save(), 'word/document.xml');
    expect(xml, contains('<w:t xml:space="preserve">  Centered</w:t><w:tab/><w:t>line</w:t><w:br/><w:t xml:space="preserve">next </w:t>'));
    expect(DocxReader.read(editor.save()).blocks.whereType<DocxParagraph>().elementAt(5).text, '  Centered\tline\nnext ');
  });

  test('Enter splits a paragraph and Backspace at the start joins it back', () {
    final next = editor.splitParagraph(2, 'Plain start, bold'.length);
    expect(para(2).text, 'Plain start, bold');
    expect(para(next).text, ' part and italic red');
    expect(para(next).runs.first.bold, isTrue);
    expect(para(2).runs.last.bold, isTrue);
    final cursor = editor.joinWithPrevious(next);
    expect(cursor, 'Plain start, bold'.length);
    expect(para(2).text, 'Plain start, bold part and italic red');
  });

  test('Enter at the end of a heading continues in body text', () {
    final next = editor.splitParagraph(1, para(1).text.length);
    expect(para(next).headingLevel, 0);
    expect(para(next).text, '');
    editor.setParagraphText(next, 'New body text');
    expect(para(next).text, 'New body text');
    expect(para(1).headingLevel, 1);
  });

  test('Enter at the end of a bullet makes another bullet', () {
    final next = editor.splitParagraph(4, para(4).text.length);
    expect(para(next).listLevel, 0);
  });

  test('a picture stays put when Enter is pressed after it', () {
    final pictures = editor.document.blocks.whereType<DocxImage>().length;
    final next = editor.splitParagraph(6, 0 + para(6).text.length);
    final blocks = editor.document.blocks;
    expect(blocks.whereType<DocxImage>().length, pictures);
    final image = blocks.indexWhere((b) => b is DocxImage);
    final newParagraph = blocks.indexWhere((b) => b is DocxParagraph && b.ref == next);
    expect(image, lessThan(newParagraph));
  });

  test('character formatting splits runs and keeps properties in schema order', () {
    editor.setBold(5, 0, 8, true); // "Centered"
    editor.setFontSize(5, 0, 8, 16);
    editor.setColor(5, 0, 8, '0070C0');
    editor.setItalic(5, 0, 8, true);
    final runs = para(5).runs;
    expect(runs.map((r) => r.text), ['Centered', ' line']);
    expect(runs[0].bold && runs[0].italic, isTrue);
    expect(runs[0].fontSizePt, 16);
    expect(runs[0].color, '0070C0');
    expect(runs[1].bold, isFalse);
    final xml = part(editor.save(), 'word/document.xml');
    expect(xml, contains('<w:rPr><w:b/><w:bCs/><w:i/><w:iCs/><w:color w:val="0070C0"/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr><w:t>Centered</w:t>'));
    editor.setBold(5, 0, 8, false);
    expect(para(5).runs[0].bold, isFalse);
  });

  test('an empty selection formats the whole paragraph and its mark', () {
    editor.setUnderline(0, 0, 0, true);
    expect(para(0).runs.single.underline, isTrue);
    expect(part(editor.save(), 'word/document.xml'), contains('<w:pPr><w:pStyle w:val="Title"/><w:rPr><w:u w:val="single"/></w:rPr></w:pPr>'));
  });

  test('alignment, headings and bullets', () {
    editor.setAlignment(2, ParagraphAlign.right);
    expect(para(2).align, ParagraphAlign.right);
    editor.setParagraphKind(2, DocxParagraphKind.heading2);
    expect(para(2).headingLevel, 2);
    editor.setParagraphKind(2, DocxParagraphKind.normal);
    expect(para(2).headingLevel, 0);
    editor.toggleBullets(2);
    expect(para(2).listLevel, 0);
    editor.toggleBullets(3); // a List Bullet style paragraph becomes plain
    expect(para(3).listLevel, isNull);
    final xml = part(editor.save(), 'word/document.xml');
    expect(xml, contains('<w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="'));
    expect(xml, contains('<w:jc w:val="right"/>'));
  });

  test('adds standard heading styles and bullet numbering when a document lacks them', () {
    final bare = DocxEditor.open(_bareDocx());
    bare.setParagraphKind(0, DocxParagraphKind.heading1);
    bare.toggleBullets(1);
    final bytes = bare.save();
    keep('bare-edited.docx', bytes);
    final reread = DocxReader.read(bytes);
    final ps = reread.blocks.whereType<DocxParagraph>().toList();
    expect(ps[0].headingLevel, 1);
    expect(ps[1].listLevel, 0);
    expect(part(bytes, '[Content_Types].xml'), contains('/word/numbering.xml'));
    expect(part(bytes, 'word/_rels/document.xml.rels'), contains('numbering.xml'));
    expect(part(bytes, 'word/styles.xml'), contains('w:styleId="Heading1"'));
  });

  test('table cells can be edited', () {
    editor.setCellText(0, 1, 1, '3-4\nweeks');
    final table = editor.document.blocks.whereType<DocxTable>().single;
    expect(table.rows[1][1], '3-4\nweeks');
    editor.setCellText(0, 1, 1, 'Done');
    expect(editor.document.blocks.whereType<DocxTable>().single.rows[1][1], 'Done');
  });

  test('undo goes back one step at a time', () {
    editor.checkpoint();
    editor.setParagraphText(0, 'Project Brief v2');
    editor.setBold(0, 0, 0, true);
    expect(editor.undo(), isTrue);
    expect(para(0).runs.single.bold, isFalse);
    expect(para(0).text, 'Project Brief v2');
    expect(editor.undo(), isTrue);
    expect(para(0).text, 'Project Brief');
  });

  test('saving copies untouched parts byte for byte', () {
    editor.setParagraphText(0, 'Project Brief (final)');
    editor.splitParagraph(2, 5);
    editor.setBold(1, 0, 3, true);
    final bytes = editor.save();
    keep('edited.docx', bytes);
    final original = ZipDecoder().decodeBytes(fixture('sample.docx'));
    final saved = ZipDecoder().decodeBytes(bytes);
    expect(saved.files.map((f) => f.name).toSet(), original.files.map((f) => f.name).toSet());
    for (final f in original.files) {
      if (f.name == 'word/document.xml') continue;
      expect(saved.findFile(f.name)!.content, f.content, reason: f.name);
    }
    expect(DocxReader.read(bytes).blocks.whereType<DocxParagraph>().first.text, 'Project Brief (final)');
  });
}

List<int> _bareDocx() {
  const w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'))
    ..addFile(ArchiveFile.string('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'))
    ..addFile(ArchiveFile.string('word/document.xml',
        '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="$w"><w:body><w:p><w:r><w:t>Heading text</w:t></w:r></w:p>'
            '<w:p><w:r><w:t>Item</w:t></w:r></w:p><w:sectPr/></w:body></w:document>'));
  return ZipEncoder().encodeBytes(archive);
}
