import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

enum PageSizeChoice {
  a4('A4'),
  letter('Letter'),
  fit('Fit photo');

  const PageSizeChoice(this.label);

  final String label;
}

/// A picture to put on its own page, turned by [quarterTurns] clockwise.
class PageImage {
  const PageImage(this.bytes, {this.quarterTurns = 0});

  final Uint8List bytes;
  final int quarterTurns;

  PageImage turned() => PageImage(bytes, quarterTurns: (quarterTurns + 1) % 4);
}

/// Long edge of a picture after "smaller file" is chosen: sharp on a phone
/// and when printed at A4, a fraction of a camera photo's size.
const smallerLongEdge = 2000;

bool isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;
bool isPng(Uint8List b) => b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

/// Makes one PDF with a page per picture.
///
/// JPEG and PNG pictures go in untouched unless [smaller] is set. Others
/// (HEIC, WebP and so on) are decoded by the phone and saved as JPEG.
Future<Uint8List> imagesToPdf(List<PageImage> images, {PageSizeChoice size = PageSizeChoice.a4, bool margins = true, bool smaller = false, String title = ''}) async {
  if (images.isEmpty) throw ArgumentError('No pictures to put in the PDF.');
  final prepared = <PageImage>[];
  for (final image in images) {
    prepared.add(PageImage(await preparePicture(image.bytes, smaller: smaller), quarterTurns: image.quarterTurns));
  }
  return compute(_build, (images: prepared, size: size, margins: margins, title: title));
}

/// Returns bytes the PDF library can embed: the original JPEG or PNG when
/// possible, otherwise a JPEG decoded and re-encoded through the phone's own
/// image decoder (which also applies the camera's orientation).
Future<Uint8List> preparePicture(Uint8List bytes, {bool smaller = false}) async {
  if (!smaller && (isJpeg(bytes) || isPng(bytes))) return bytes;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      var width = descriptor.width;
      var height = descriptor.height;
      final long = math.max(width, height);
      if (smaller && long > smallerLongEdge) {
        width = (width * smallerLongEdge / long).round();
        height = (height * smallerLongEdge / long).round();
      }
      final codec = await descriptor.instantiateCodec(targetWidth: width, targetHeight: height);
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          final rgba = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
          if (rgba == null) throw StateError('A picture could not be read.');
          final encoded = await compute(_encodeJpeg, (rgba: rgba.buffer.asUint8List(), width: image.width, height: image.height));
          // A small PNG (a screenshot, say) can be smaller than its JPEG.
          if (isPng(bytes) && bytes.length <= encoded.length) return bytes;
          return encoded;
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

Uint8List _encodeJpeg(({Uint8List rgba, int width, int height}) m) {
  final image = img.Image.fromBytes(width: m.width, height: m.height, bytes: m.rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
  // JPEG has no transparency: put see-through parts on white paper.
  final white = img.Image(width: m.width, height: m.height)..clear(img.ColorRgb8(255, 255, 255));
  img.compositeImage(white, image);
  return img.encodeJpg(white, quality: 85);
}

Future<Uint8List> _build(({List<PageImage> images, PageSizeChoice size, bool margins, String title}) m) async {
  final doc = pw.Document(title: m.title.isEmpty ? null : m.title, creator: 'Doc Reader');
  final margin = m.margins ? 24.0 : 0.0;
  for (final page in m.images) {
    final picture = pw.MemoryImage(page.bytes);
    // Width and height as shown, after the camera's orientation and the
    // user's turns.
    var w = (picture.width ?? 1).toDouble();
    var h = (picture.height ?? 1).toDouble();
    if (page.quarterTurns.isOdd) (w, h) = (h, w);
    final landscape = w > h;
    final PdfPageFormat format;
    switch (m.size) {
      case PageSizeChoice.a4:
        format = landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
      case PageSizeChoice.letter:
        format = landscape ? PdfPageFormat.letter.landscape : PdfPageFormat.letter;
      case PageSizeChoice.fit:
        // The picture's shape, with its long edge as long as A4's.
        final long = PdfPageFormat.a4.height;
        final scale = long / math.max(w, h);
        format = PdfPageFormat(w * scale + 2 * margin, h * scale + 2 * margin);
    }
    doc.addPage(pw.Page(
      pageFormat: format.copyWith(marginLeft: margin, marginRight: margin, marginTop: margin, marginBottom: margin),
      build: (_) => pw.Center(
        child: page.quarterTurns == 0
            ? pw.Image(picture, fit: pw.BoxFit.contain)
            : pw.Transform.rotateBox(angle: -page.quarterTurns * math.pi / 2, child: pw.Image(picture, fit: pw.BoxFit.contain)),
      ),
    ));
  }
  return doc.save();
}
