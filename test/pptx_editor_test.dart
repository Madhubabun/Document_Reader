import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:doc_reader/services/ooxml/ooxml_editor.dart';
import 'package:doc_reader/services/ooxml/pptx_editor.dart';
import 'package:doc_reader/services/ooxml/pptx_reader.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

String part(List<int> pptx, String name) => utf8.decode(ZipDecoder().decodeBytes(pptx).findFile(name)!.content as List<int>);

/// Writes edited files to $PPTX_OUT so they can be opened in PowerPoint.
void keep(String name, List<int> bytes) {
  final dir = Platform.environment['PPTX_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

void main() {
  late PptxEditor editor;
  setUp(() => editor = PptxEditor.open(fixture('sample.pptx')));

  PptxShape shape(int slide, String text) => editor.presentation.slides[slide].shapes.firstWhere((s) => s.text.contains(text));

  test('shapes carry refs back to the XML', () {
    expect(editor.presentation.slides, hasLength(2));
    expect(shape(1, 'Footnote').ref, isNotNull);
    expect(shape(1, 'Revenue').placeholder, isTrue);
  });

  test('editing text keeps run formatting and unchanged paragraphs', () {
    final body = shape(1, 'Revenue');
    editor.setShapeText(1, body.ref!, 'Revenue up 12%\nNew markets\nLower costs');
    final updated = shape(1, 'Revenue');
    expect(updated.paragraphs.map((p) => p.text), ['Revenue up 12%', 'New markets', 'Lower costs']);
    expect(updated.paragraphs[1].level, 1);
    expect(updated.paragraphs[2].level, 1); // a new line continues the last paragraph's level

    final foot = shape(1, 'Footnote');
    editor.setShapeText(1, foot.ref!, 'Footnote: draft');
    expect(shape(1, 'Footnote').paragraphs.single.runs.single.bold, isTrue);
    expect(shape(1, 'Footnote').paragraphs.single.runs.single.fontSizePt, 12);
  });

  test('formatting a whole shape', () {
    final ref = shape(1, 'Footnote').ref!;
    editor.setBold(1, ref, false);
    editor.setItalic(1, ref, true);
    editor.setFontSize(1, ref, 20);
    editor.setColor(1, ref, 'C00000');
    editor.setAlignment(1, ref, 'ctr');
    final run = shape(1, 'Footnote').paragraphs.single.runs.single;
    expect(run.bold, isFalse);
    expect(run.italic, isTrue);
    expect(run.fontSizePt, 20);
    expect(run.color, 'C00000');
    expect(shape(1, 'Footnote').paragraphs.single.align, 'ctr');
    expect(part(editor.save(), 'ppt/slides/slide2.xml'),
        contains('<a:rPr b="0" sz="2000" i="1"><a:solidFill><a:srgbClr val="C00000"/></a:solidFill></a:rPr><a:t>Footnote</a:t>'));
  });

  test('moving a placeholder gives it its own position', () {
    final title = shape(1, 'Results');
    editor.setRect(1, title.ref!, const EmuRect(100, 200, 3000000, 900000));
    final moved = shape(1, 'Results').rect!;
    expect([moved.x, moved.y, moved.width, moved.height], [100, 200, 3000000, 900000]);
    expect(part(editor.save(), 'ppt/slides/slide2.xml'), contains('<p:spPr><a:xfrm><a:off x="100" y="200"/><a:ext cx="3000000" cy="900000"/></a:xfrm></p:spPr>'));
  });

  test('text boxes can be added and deleted', () {
    final ref = editor.addTextBox(0, 'Hello & welcome');
    expect(editor.presentation.slides[0].shapes.firstWhere((s) => s.ref == ref).text, 'Hello & welcome');
    editor.deleteShape(0, ref);
    expect(editor.presentation.slides[0].shapes.where((s) => s.text.contains('Hello')), isEmpty);
  });

  test('slides can be added, duplicated, moved and deleted', () {
    final added = editor.addSlide(1);
    expect(added, 2);
    final slides = editor.presentation.slides;
    expect(slides, hasLength(3));
    // The new slide shows its layout's empty placeholders, ready for typing.
    expect(slides[2].shapes.where((s) => s.placeholder), isNotEmpty);
    final title = slides[2].shapes.firstWhere((s) => s.kind == PptxShapeKind.title);
    editor.setShapeText(2, title.ref!, 'Next steps');
    expect(editor.presentation.slides[2].title, 'Next steps');

    final copy = editor.duplicateSlide(0);
    expect(copy, 1);
    expect(editor.presentation.slides.map((s) => s.title), ['Q3 Highlights', 'Q3 Highlights', 'Results', 'Next steps']);
    editor.moveSlide(3, 0);
    expect(editor.presentation.slides.map((s) => s.title), ['Next steps', 'Q3 Highlights', 'Q3 Highlights', 'Results']);
    editor.deleteSlide(1);
    expect(editor.presentation.slides.map((s) => s.title), ['Next steps', 'Q3 Highlights', 'Results']);

    final bytes = editor.save();
    keep('edited.pptx', bytes);
    final reread = PptxReader.read(bytes);
    expect(reread.slides.map((s) => s.title), ['Next steps', 'Q3 Highlights', 'Results']);
    final types = part(bytes, '[Content_Types].xml');
    expect(types, isNot(contains('/ppt/slides/slide1.xml"')));
    expect(ZipDecoder().decodeBytes(bytes).findFile('ppt/slides/slide1.xml'), isNull);
  });

  test('the last slide cannot be deleted', () {
    editor.deleteSlide(0);
    expect(() => editor.deleteSlide(0), throwsA(isA<EditRefused>()));
  });

  test('undo and untouched parts', () {
    editor.setShapeText(0, shape(0, 'Q3').ref!, 'Q4 Highlights');
    editor.undo();
    expect(editor.presentation.slides[0].title, 'Q3 Highlights');
    editor.setShapeText(0, shape(0, 'Q3').ref!, 'Q4 Highlights');
    final original = ZipDecoder().decodeBytes(fixture('sample.pptx'));
    final saved = ZipDecoder().decodeBytes(editor.save());
    for (final f in original.files) {
      if (f.name == 'ppt/slides/slide1.xml') continue;
      expect(saved.findFile(f.name)!.content, f.content, reason: f.name);
    }
  });
}
