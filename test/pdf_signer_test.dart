import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:doc_reader/services/pdf_signer.dart';
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
SignaturePlacement half(int page, Rect rect) {
  final rgba = Uint8List(20 * 10 * 4);
  for (var y = 0; y < 10; y++) {
    for (var x = 0; x < 10; x++) {
      final i = (y * 20 + x) * 4;
      rgba[i] = 255;
      rgba[i + 3] = 255;
    }
  }
  return SignaturePlacement(pageNumber: page, rect: rect, rgba: rgba, width: 20, height: 10);
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
    final signed = await stampSignatures(source, [half(1, box), half(2, box)]);
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
    final signed = await stampSignatures(source, [half(1, const Rect.fromLTWH(0.1, 0.1, 0.5, 0.1))], password: '1234');
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
}
