import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:doc_reader/services/images_to_pdf.dart';
import 'package:doc_reader/services/pdf_encrypt.dart';
import 'package:doc_reader/services/pdf_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' as gen;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

/// Set PDFIUM_PATH to a libpdfium build to run these tests.
final pdfium = Platform.environment['PDFIUM_PATH'];

/// Writes results to $PDF_OUT so they can be checked in other readers.
void keep(String name, List<int> bytes) {
  final dir = Platform.environment['PDF_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// [count] pages, page n being (300 + n) points wide and saying "Page n".
Future<Uint8List> numbered(int count, {String prefix = 'Page'}) {
  final doc = pw.Document(compress: true);
  for (var n = 1; n <= count; n++) {
    doc.addPage(pw.Page(
      pageFormat: gen.PdfPageFormat(300.0 + n, 400),
      build: (_) => pw.Center(child: pw.Text('$prefix $n (${String.fromCharCode(0x28)}brackets) \\ done')),
    ));
  }
  return doc.save();
}

Future<List<int>> widths(Uint8List pdf, {String? password}) async {
  final doc = await openPdfData(pdf, password);
  final result = [for (final p in doc.pages) p.width.round() - 300];
  await doc.dispose();
  return result;
}

Future<String> textOf(Uint8List pdf, int page, {String? password}) async {
  final doc = await openPdfData(pdf, password);
  final text = (await doc.pages[page - 1].loadStructuredText()).fullText;
  await doc.dispose();
  return text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => Pdfrx.pdfiumModulePath = pdfium);
  final skip = pdfium == null ? 'Set PDFIUM_PATH' : null;

  test('merge keeps every page in order', () async {
    final merged = await mergePdfs([PdfSource(await numbered(2)), PdfSource(fixture('locked.pdf'), password: '1234'), PdfSource(await numbered(3))]);
    keep('merged.pdf', merged);
    final w = await widths(merged);
    final locked = await widths(fixture('locked.pdf'), password: '1234');
    expect(w, [1, 2, ...locked, 1, 2, 3]);
    expect(await needsPassword(merged), isFalse);
    await expectLater(mergePdfs([PdfSource(await numbered(1)), PdfSource(fixture('locked.pdf'))]), throwsA(isA<PdfToolError>()));
  }, skip: skip);

  test('split makes one file per group', () async {
    final files = await splitPdf(PdfSource(await numbered(5)), [
      [1, 2],
      [3],
      [5, 4],
    ]);
    expect(files, hasLength(3));
    expect(await widths(files[0]), [1, 2]);
    expect(await widths(files[1]), [3]);
    expect(await widths(files[2]), [5, 4]);
    expect(await textOf(files[2], 1), contains('Page 5'));
    await expectLater(splitPdf(PdfSource(await numbered(2)), [
      [3],
    ]), throwsA(isA<PdfToolError>()));
  }, skip: skip);

  test('organize reorders, removes and turns pages and keeps the password', () async {
    final source = await numbered(5);
    final out = await organizePdf(PdfSource(source), const [PagePlan(4), PagePlan(1, quarterTurns: 1), PagePlan(3, quarterTurns: 2), PagePlan(2)]);
    final doc = await PdfDocument.openData(out);
    expect([for (final p in doc.pages) p.rotation], [PdfPageRotation.none, PdfPageRotation.clockwise90, PdfPageRotation.clockwise180, PdfPageRotation.none]);
    await doc.dispose();
    // Text comes out in reading order, so turned pages read differently;
    // the digit tells the pages apart.
    for (final (page, number) in [(1, 4), (2, 1), (3, 3), (4, 2)]) {
      expect(RegExp(r'\d').allMatches(await textOf(out, page)).map((m) => m.group(0)), ['$number'], reason: 'page $page');
    }

    final locked = await organizePdf(PdfSource(fixture('locked.pdf'), password: '1234'), const [PagePlan(1, quarterTurns: 3)]);
    expect(await needsPassword(locked), isTrue);
    expect(await widths(locked, password: '1234'), hasLength(1));
    expect(() => organizePdf(PdfSource(source), const [PagePlan(1), PagePlan(1)]), throwsA(isA<PdfToolError>()));
  }, skip: skip);

  test('unlock removes the password; lock adds one that readers accept', () async {
    final open = await unlockPdf(PdfSource(fixture('locked.pdf'), password: '1234'));
    expect(await needsPassword(open), isFalse);
    await expectLater(unlockPdf(PdfSource(fixture('locked.pdf'), password: 'nope')), throwsA(isA<PdfToolError>()));

    for (final (name, source) in [('numbered', await numbered(3)), ('form', fixture('form.pdf')), ('relocked', fixture('locked.pdf'))]) {
      final password = name == 'relocked' ? '1234' : null;
      final locked = await lockPdf(PdfSource(source, password: password), 'pässwörd 1');
      keep('locked-$name.pdf', locked);
      expect(await needsPassword(locked), isTrue, reason: name);
      // The right password opens it, the old one doesn't.
      expect(await widths(locked, password: 'pässwörd 1'), await widths(source, password: password), reason: name);
      await expectLater(unlockPdf(PdfSource(locked, password: 'wrong')), throwsA(isA<PdfToolError>()));
      if (name == 'numbered') expect(await textOf(locked, 2, password: 'pässwörd 1'), contains('Page 2 ((brackets) \\ done'));
      // And unlocking it again gives the pages back.
      final again = await unlockPdf(PdfSource(locked, password: 'pässwörd 1'));
      expect(await needsPassword(again), isFalse);
    }
  }, skip: skip);

  test('the encryptor refuses files it cannot handle', () async {
    // The pdf package writes a cross-reference stream; PDFium rewrites it
    // with a table before locking.
    final withStream = await numbered(1);
    expect(() => encryptPdf(withStream, 'x'), throwsFormatException);
    expect(() => encryptPdf(Uint8List.fromList('%PDF-1.4 nonsense'.codeUnits), 'x'), throwsFormatException);
  });

  test('the hardened hash matches the published algorithm', () {
    // Deterministic: same inputs, same output, 32 bytes.
    final random = Random(7);
    final a = encryptPdf(_tinyPdf, 'abc', random: random);
    expect(String.fromCharCodes(a.take(8)), '%PDF-1.7');
    expect(String.fromCharCodes(a), contains('/V 5/R 6'));
  });

  test('compress shrinks big photos and keeps the page looking the same', () async {
    // A noisy 2400 x 1800 photo stored as PNG: big, and worth shrinking.
    final photo = img.Image(width: 2400, height: 1800);
    final rng = Random(1);
    for (var y = 0; y < 1800; y++) {
      for (var x = 0; x < 2400; x++) {
        photo.setPixelRgb(x, y, (x ~/ 10 + rng.nextInt(20)) % 256, (y ~/ 8) % 256, 120 + rng.nextInt(30));
      }
    }
    // A see-through logo that must be left alone.
    final logo = img.Image(width: 400, height: 400, numChannels: 4);
    for (var y = 0; y < 400; y++) {
      for (var x = 0; x < 400; x++) {
        logo.setPixelRgba(x, y, 255, 0, 0, (x + y) % 255);
      }
    }
    final doc = pw.Document();
    doc.addPage(pw.Page(pageFormat: gen.PdfPageFormat.a4, build: (_) => pw.Image(pw.MemoryImage(img.encodePng(photo)))));
    doc.addPage(pw.Page(pageFormat: gen.PdfPageFormat.a4, build: (_) => pw.Image(pw.MemoryImage(img.encodePng(logo)), width: 200)));
    doc.addPage(pw.Page(pageFormat: gen.PdfPageFormat.a4, build: (_) => pw.Text('Only words here')));
    final source = await doc.save();

    final result = await compressPdf(PdfSource(source), CompressLevel.balanced);
    keep('compressed.pdf', result.bytes);
    expect(result.imagesChanged, 1);
    expect(result.bytes.length, lessThan(source.length ~/ 3));
    expect(await textOf(result.bytes, 3), contains('Only words here'));
    expect(await widths(result.bytes), await widths(source));

    // Already-small files come back unchanged.
    final small = await imagesToPdf([PageImage(Uint8List.fromList(img.encodeJpg(img.Image(width: 300, height: 200), quality: 50)))]);
    final same = await compressPdf(PdfSource(small), CompressLevel.strong);
    expect(same.imagesChanged, 0);
    expect(same.bytes, small);

    // One picture shown on several pages, like a letterhead, is stored once
    // and shrunk once; the first page shows it big, the others small.
    final shared = pw.MemoryImage(img.encodePng(img.copyResize(photo, width: 1200)));
    final letters = pw.Document();
    letters.addPage(pw.Page(pageFormat: gen.PdfPageFormat.a4, build: (_) => pw.Image(shared)));
    for (var n = 2; n <= 3; n++) {
      letters.addPage(pw.Page(pageFormat: gen.PdfPageFormat.a4, build: (_) => pw.Column(children: [pw.Image(shared, width: 120), pw.Text('Letter $n')])));
    }
    final lettersPdf = await letters.save();
    final smaller = await compressPdf(PdfSource(lettersPdf), CompressLevel.balanced);
    expect(smaller.imagesChanged, greaterThan(0));
    expect(smaller.pagesSkipped, 0);
    expect(smaller.bytes.length, lessThan(lettersPdf.length ~/ 3));
    expect(await textOf(smaller.bytes, 3), contains('Letter 3'));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}

/// The smallest valid PDF with a classic xref table.
final _tinyPdf = () {
  final objects = [
    '<</Type/Catalog/Pages 2 0 R>>',
    '<</Type/Pages/Kids[3 0 R]/Count 1>>',
    '<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>',
    '<</Length 21>>\nstream\nBT /F1 12 Tf (Hi) ET\nendstream',
  ];
  final b = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(b.length);
    b.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = b.length;
  b.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f\r\n');
  for (final o in offsets) {
    b.write('${o.toString().padLeft(10, '0')} 00000 n\r\n');
  }
  b.write('trailer\n<</Size ${objects.length + 1}/Root 1 0 R>>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(b.toString().codeUnits);
}();
