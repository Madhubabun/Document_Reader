import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:doc_reader/services/pdf_edits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as gen;
import 'package:pdfrx/pdfrx.dart';

/// Set PDFIUM_PATH to a libpdfium build to run these tests.
final pdfium = Platform.environment['PDFIUM_PATH'];

/// Writes signed files to $PDF_OUT so they can be checked in other readers.
void keep(String name, List<int> bytes) {
  final dir = Platform.environment['PDF_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

/// A blank portrait page and a blank page shown rotated a quarter turn.
Future<Uint8List> blankPdf() async {
  final doc = gen.PdfDocument();
  gen.PdfPage(doc, pageFormat: gen.PdfPageFormat.a4);
  gen.PdfPage(doc, pageFormat: gen.PdfPageFormat.a4, rotate: gen.PdfPageRotation.rotate90);
  return doc.save();
}

/// A 20 x 10 image: the left half opaque red, the right half transparent.
ImageEdit half(int page, Rect rect) {
  final rgba = Uint8List(20 * 10 * 4);
  for (var y = 0; y < 10; y++) {
    for (var x = 0; x < 10; x++) {
      final i = (y * 20 + x) * 4;
      rgba[i] = 255;
      rgba[i + 3] = 255;
    }
  }
  return ImageEdit(page, rect: rect, rgba: rgba, width: 20, height: 10);
}

void main() {
  setUpAll(() => Pdfrx.pdfiumModulePath = pdfium);

  /// Renders [page] 200 wide and returns a pixel test for fractions.
  Future<bool Function(double, double)> redAt(PdfDocument doc, int page) async {
    final p = doc.pages[page - 1];
    final width = 200;
    final height = (200 * p.height / p.width).round();
    final image = (await p.render(fullWidth: width.toDouble(), fullHeight: height.toDouble(), width: width, height: height, backgroundColor: 0xFFFFFFFF))!;
    final pixels = image.pixels;
    image.dispose();
    return (fx, fy) {
      final i = ((fy * height).floor() * width + (fx * width).floor()) * 4;
      // BGRA
      return pixels[i + 2] > 200 && pixels[i + 1] < 60 && pixels[i] < 60;
    };
  }

  test('signatures land where they were placed, with transparency', () async {
    final source = await blankPdf();
    const box = Rect.fromLTWH(0.5, 0.7, 0.4, 0.1);
    final signed = await applyPdfEdits(source, [half(1, box), half(2, box)]);
    keep('signed.pdf', signed);

    // This file has a cross-reference stream, so it is rewritten in full.
    expect(usesXrefTable(source), isFalse);
    expect(usesXrefTable(signed), isTrue);

    final reopened = await PdfDocument.openData(signed);
    for (final page in [1, 2]) {
      final red = await redAt(reopened, page);
      expect(red(0.6, 0.75), isTrue, reason: 'left half is red on page $page');
      expect(red(0.8, 0.75), isFalse, reason: 'right half is see-through on page $page');
      expect(red(0.3, 0.75), isFalse, reason: 'nothing outside the box on page $page');
      expect(red(0.6, 0.6), isFalse, reason: 'nothing above the box on page $page');
    }
    await reopened.dispose();
  }, skip: pdfium == null);

  test('password-protected files stay protected and open with their password', () async {
    final source = File('test/fixtures/locked.pdf').readAsBytesSync();
    final signed = await applyPdfEdits(source, [half(1, const Rect.fromLTWH(0.1, 0.1, 0.5, 0.1))], password: '1234');
    // A classic cross-reference table: the original bytes are kept and the
    // signature is appended.
    expect(usesXrefTable(source), isTrue);
    expect(signed.sublist(0, source.length), source);
    await expectLater(PdfDocument.openData(signed), throwsA(isA<PdfPasswordException>()));
    keep('locked-signed.pdf', signed);
    final reopened = await PdfDocument.openData(signed, passwordProvider: () => '1234');
    final red = await redAt(reopened, 1);
    expect(red(0.2, 0.15), isTrue);
    await reopened.dispose();
  }, skip: pdfium == null);

  test('highlights, underlines and drawings are saved as standard annotations', () async {
    final source = await blankPdf();
    final signed = await applyPdfEdits(source, [
      const MarkupEdit(1, kind: MarkupKind.highlight, lines: [Rect.fromLTWH(0.1, 0.1, 0.5, 0.03), Rect.fromLTWH(0.1, 0.14, 0.3, 0.03)], color: 0xFFFFEB3B),
      const MarkupEdit(1, kind: MarkupKind.underline, lines: [Rect.fromLTWH(0.1, 0.3, 0.5, 0.03)], color: 0xFF2196F3),
      const MarkupEdit(2, kind: MarkupKind.strikeout, lines: [Rect.fromLTWH(0.1, 0.3, 0.5, 0.03)], color: 0xFFF44336),
      const InkEdit(1, strokes: [
        [Offset(0.2, 0.5), Offset(0.5, 0.5), Offset(0.8, 0.5)],
      ], color: 0xFFFF0000, width: 0.01),
      const InkEdit(2, strokes: [
        [Offset(0.2, 0.6), Offset(0.8, 0.6)],
      ], color: 0xFF00C853, width: 0.03, opacity: 0.4),
    ]);
    keep('annotated.pdf', signed);
    final text = String.fromCharCodes(signed);
    for (final subtype in ['Highlight', 'Underline', 'StrikeOut', 'Ink']) {
      expect(text, contains('/Subtype/$subtype'), reason: subtype);
    }
    // Appearance streams are written, so every reader shows them.
    expect(RegExp(r'/AP\s*<<').allMatches(text).length, greaterThanOrEqualTo(5));

    final doc = await PdfDocument.openData(signed);
    final p1 = doc.pages[0];
    final image = (await p1.render(fullWidth: 200, fullHeight: 200 * p1.height / p1.width, backgroundColor: 0xFFFFFFFF))!;
    final w = image.width;
    final h = image.height;
    final px = image.pixels;
    image.dispose();
    List<int> at(double fx, double fy) {
      final i = ((fy * h).floor() * w + (fx * w).floor()) * 4;
      return [px[i + 2], px[i + 1], px[i]]; // RGB
    }

    final yellow = at(0.3, 0.115);
    expect(yellow[0] > 200 && yellow[1] > 200 && yellow[2] < 120, isTrue, reason: 'highlight is yellow: $yellow');
    final red = at(0.5, 0.5);
    expect(red[0] > 200 && red[1] < 80, isTrue, reason: 'ink is red: $red');
    final blank = at(0.5, 0.8);
    expect(blank, [255, 255, 255]);
    await doc.dispose();
  }, skip: pdfium == null);

  test('form fields are listed and filled in', () async {
    final source = File('test/fixtures/form.pdf').readAsBytesSync();
    final fields = await readFormFields(source);
    final byName = <String, List<PdfFormField>>{};
    for (final f in fields) {
      byName.putIfAbsent(f.name, () => []).add(f);
    }
    expect(byName.keys.toSet(), {'name', 'notes', 'agree', 'size', 'country', 'locked'});
    final name = byName['name']!.single;
    expect(name.kind, FormFieldKind.text);
    expect(name.rect.left, closeTo(150 / 595.27, 0.01));
    expect(name.rect.top, closeTo((841.89 - 802) / 841.89, 0.01));
    expect(byName['notes']!.single.multiline, isTrue);
    expect(byName['agree']!.single.kind, FormFieldKind.checkbox);
    expect(byName['size'], hasLength(3));
    expect(byName['size']!.every((f) => f.kind == FormFieldKind.radio && !f.checked), isTrue);
    final country = byName['country']!.single;
    expect(country.kind, FormFieldKind.choice);
    expect(country.options, ['India', 'Germany', 'Japan']);
    expect(country.selected, 0);
    expect(byName['locked']!.single.readOnly, isTrue);

    final medium = byName['size']![1];
    final filled = await applyPdfEdits(source, [
      FieldEdit(1, annotIndex: name.annotIndex, text: 'Ada Lovelace'),
      FieldEdit(1, annotIndex: byName['notes']!.single.annotIndex, text: 'Line one\nLine two'),
      FieldEdit(1, annotIndex: byName['agree']!.single.annotIndex, checked: true),
      FieldEdit(1, annotIndex: medium.annotIndex, checked: true),
      FieldEdit(1, annotIndex: country.annotIndex, option: 2),
      // An annotation in the same save must not disturb the field indexes.
      const MarkupEdit(1, kind: MarkupKind.highlight, lines: [Rect.fromLTWH(0.05, 0.05, 0.1, 0.02)], color: 0xFFFFEB3B),
    ]);
    keep('filled.pdf', filled);
    final again = {for (final f in await readFormFields(filled)) '${f.name}#${f.annotIndex}': f};
    String value(String n) => again.values.firstWhere((f) => f.name == n).value;
    expect(value('name'), 'Ada Lovelace');
    expect(value('notes').replaceAll('\r\n', '\n').replaceAll('\r', '\n'), 'Line one\nLine two');
    expect(again.values.firstWhere((f) => f.name == 'agree').checked, isTrue);
    expect(again.values.where((f) => f.name == 'size').map((f) => f.checked), [false, true, false]);
    expect(value('country'), 'Japan');
    expect(value('locked'), 'fixed');

    // Unchecking a box works too.
    final unchecked = await applyPdfEdits(filled, [FieldEdit(1, annotIndex: byName['agree']!.single.annotIndex, checked: false)]);
    expect((await readFormFields(unchecked)).firstWhere((f) => f.name == 'agree').checked, isFalse);
  }, skip: pdfium == null);

  test('a wrong password is reported plainly', () async {
    final source = File('test/fixtures/locked.pdf').readAsBytesSync();
    await expectLater(applyPdfEdits(source, [half(1, const Rect.fromLTWH(0.1, 0.1, 0.5, 0.1))], password: 'nope'), throwsA(isA<StateError>()));
  }, skip: pdfium == null);

  test('an invisible text layer makes scanned pages searchable', () async {
    final source = await blankPdf();
    const line = Rect.fromLTWH(0.2, 0.3, 0.5, 0.05);
    final out = await applyPdfEdits(source, [
      const TextLayerEdit(1, lines: [(text: 'Invoice total 42', rect: line), (text: '  ', rect: line)]),
      const TextLayerEdit(2, lines: [(text: 'Turned page words', rect: line)]),
    ]);
    keep('text-layer.pdf', out);
    final doc = await PdfDocument.openData(out);
    for (final (n, words) in [(1, 'Invoice total 42'), (2, 'Turned page words')]) {
      final page = doc.pages[n - 1];
      final text = (await page.loadText())!;
      expect(text.fullText.trim(), words);
      // The words sit over the box they were read from.
      final first = text.charRects.first.toRect(page: page);
      final last = text.charRects.last.toRect(page: page);
      expect(first.left / page.width, closeTo(line.left, 0.03), reason: 'page $n');
      expect(last.right / page.width, closeTo(line.right, 0.03), reason: 'page $n');
      expect(first.center.dy / page.height, closeTo(line.center.dy, 0.03), reason: 'page $n');
      // And nothing shows.
      expect((await redAt(doc, n))(0.3, 0.32), isFalse);
      final image = (await page.render(fullWidth: 100, fullHeight: 140, width: 100, height: 140, backgroundColor: 0xFFFFFFFF))!;
      expect(image.pixels.every((b) => b == 255), isTrue, reason: 'page $n stays blank');
      image.dispose();
    }
    await doc.dispose();
  }, skip: pdfium == null);

  test('text layer lines outside Windows-1252 use the embedded font', () async {
    final font = File('assets/fonts/office/Carlito-normal-400.ttf').readAsBytesSync();
    expect(fitsWinAnsi('Café “quoted” – 5€'), isTrue);
    expect(fitsWinAnsi('Łódź'), isFalse);
    final out = await applyPdfEdits(await blankPdf(), [
      const TextLayerEdit(1, lines: [(text: 'Łódź, Kraków', rect: Rect.fromLTWH(0.1, 0.1, 0.5, 0.04)), (text: 'Plain line', rect: Rect.fromLTWH(0.1, 0.2, 0.5, 0.04))]),
    ], unicodeFont: font);
    keep('text-layer-unicode.pdf', out);
    final doc = await PdfDocument.openData(out);
    final text = (await doc.pages.first.loadText())!.fullText;
    expect(text, contains('Łódź, Kraków'));
    expect(text, contains('Plain line'));
    await doc.dispose();
  }, skip: pdfium == null);
}
