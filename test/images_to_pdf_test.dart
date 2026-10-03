import 'dart:io';
import 'dart:typed_data';

import 'package:doc_reader/services/images_to_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// Set PDFIUM_PATH to a libpdfium build to check the pages by rendering.
final pdfium = Platform.environment['PDFIUM_PATH'];

/// A [w] x [h] picture: left half red, right half blue.
img.Image halves(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, x < w / 2 ? 255 : 0, 0, x < w / 2 ? 0 : 255);
    }
  }
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => Pdfrx.pdfiumModulePath = pdfium);

  /// Colour at fractions of [page], as 'red', 'blue', 'white' or 'other'.
  Future<String Function(double, double)> colours(PdfPage page) async {
    const width = 120;
    final height = (width * page.height / page.width).round();
    final image = (await page.render(fullWidth: width.toDouble(), fullHeight: height.toDouble(), width: width, height: height, backgroundColor: 0xFFFFFFFF))!;
    final px = Uint8List.fromList(image.pixels);
    image.dispose();
    return (fx, fy) {
      final i = ((fy * height).floor() * width + (fx * width).floor()) * 4;
      final (b, g, r) = (px[i], px[i + 1], px[i + 2]);
      if (r > 200 && g < 60 && b < 60) return 'red';
      if (b > 200 && r < 60 && g < 60) return 'blue';
      if (r > 240 && g > 240 && b > 240) return 'white';
      return 'other';
    };
  }

  test('one page per picture, in order, turned and sized as chosen', () async {
    final jpeg = Uint8List.fromList(img.encodeJpg(halves(200, 100), quality: 95));
    final png = Uint8List.fromList(img.encodePng(halves(100, 200)));
    final pdf = await imagesToPdf([
      PageImage(jpeg),
      PageImage(jpeg, quarterTurns: 1),
      PageImage(png),
    ], size: PageSizeChoice.a4, margins: false);
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    if (pdfium == null) return;

    final doc = await PdfDocument.openData(pdf);
    expect(doc.pages, hasLength(3));
    // A wide picture gets a landscape page; a tall one a portrait page.
    expect(doc.pages[0].width, greaterThan(doc.pages[0].height));
    expect(doc.pages[1].width, lessThan(doc.pages[1].height));
    expect(doc.pages[2].width, lessThan(doc.pages[2].height));

    final first = await colours(doc.pages[0]);
    expect(first(0.3, 0.5), 'red');
    expect(first(0.7, 0.5), 'blue');
    // Turned a quarter clockwise: the left (red) half is now on top.
    final turned = await colours(doc.pages[1]);
    expect(turned(0.5, 0.3), 'red');
    expect(turned(0.5, 0.7), 'blue');
    final third = await colours(doc.pages[2]);
    expect(third(0.3, 0.5), 'red');
    expect(third(0.7, 0.5), 'blue');
    await doc.dispose();
  });

  test('fit pages take the picture shape, margins leave white paper', () async {
    final jpeg = Uint8List.fromList(img.encodeJpg(halves(300, 100), quality: 95));
    final pdf = await imagesToPdf([PageImage(jpeg)], size: PageSizeChoice.fit, margins: true);
    if (pdfium == null) return;
    final doc = await PdfDocument.openData(pdf);
    final page = doc.pages.single;
    // 3:1 picture, long edge as long as A4, plus 24pt margins.
    expect(page.width, closeTo(841.89 + 48, 1));
    expect(page.height, closeTo(841.89 / 3 + 48, 1));
    final c = await colours(page);
    expect(c(0.01, 0.5), 'white');
    expect(c(0.2, 0.5), 'red');
    expect(c(0.8, 0.5), 'blue');
    await doc.dispose();
  });

  test('smaller files shrink big photos and keep their look', () async {
    final big = Uint8List.fromList(img.encodeJpg(halves(3000, 1500), quality: 98));
    final prepared = await preparePicture(big, smaller: true);
    expect(isJpeg(prepared), isTrue);
    expect(prepared.length, lessThan(big.length));
    final decoded = img.decodeJpg(prepared)!;
    expect([decoded.width, decoded.height], [smallerLongEdge, smallerLongEdge ~/ 2]);
    final left = decoded.getPixel(100, 500);
    expect(left.r, greaterThan(200));
    expect(left.b, lessThan(60));

    // A flat PNG stays a PNG when that is smaller.
    final flat = Uint8List.fromList(img.encodePng(halves(3000, 1500)));
    expect(await preparePicture(flat, smaller: true), same(flat));

    // Other formats are converted, transparency on white.
    final transparent = img.Image(width: 10, height: 10, numChannels: 4);
    final webpLike = Uint8List.fromList(img.encodeBmp(transparent));
    final converted = await preparePicture(webpLike);
    expect(isJpeg(converted), isTrue);
    final pixel = img.decodeJpg(converted)!.getPixel(5, 5);
    expect(pixel.r, greaterThan(240));
  });
}
