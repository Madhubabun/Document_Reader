import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_edits.dart';

/// Thrown with a message to show as is.
class OcrUnavailable implements Exception {
  const OcrUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A line of recognised text and where it is, as fractions of the picture.
typedef OcrLine = ({String text, ui.Rect rect});

/// Reads text in pictures on the phone (Google ML Kit, Latin script: English
/// and other languages written with the Latin alphabet). Nothing is uploaded.
class TextReader {
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  /// Lines of text in an encoded picture (JPEG, PNG, ...), top to bottom.
  Future<List<OcrLine>> readPicture(Uint8List bytes, {ui.Size? size}) async {
    size ??= await _size(bytes);
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'ocr-${DateTime.now().microsecondsSinceEpoch}.img'));
    await file.writeAsBytes(bytes, flush: true);
    try {
      final RecognizedText result;
      try {
        result = await _recognizer.processImage(InputImage.fromFilePath(file.path));
      } on MissingPluginException {
        throw const OcrUnavailable('Reading text is not available on this phone.');
      } on PlatformException catch (e) {
        throw OcrUnavailable('The text could not be read: ${e.message ?? e.code}');
      }
      return [
        for (final block in result.blocks)
          for (final line in block.lines)
            (
              text: line.text,
              rect: ui.Rect.fromLTRB(
                line.boundingBox.left / size.width,
                line.boundingBox.top / size.height,
                line.boundingBox.right / size.width,
                line.boundingBox.bottom / size.height,
              ),
            ),
      ];
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// The text of an encoded picture as paragraphs.
  Future<String> readPictureText(Uint8List bytes) async => joinLines(await readPicture(bytes));

  /// The picture's stored size. (Only proportions within one picture
  /// matter where camera orientation could differ.)
  Future<ui.Size> _size(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
      descriptor.dispose();
      return size;
    } finally {
      buffer.dispose();
    }
  }

  /// Text lines for every page of [doc] that has no text yet. Pages with
  /// text are left out. [onPage] reports progress (page, page count).
  Future<List<TextLayerEdit>> readScannedPages(PdfDocument doc, {void Function(int page, int count)? onPage}) async {
    final edits = <TextLayerEdit>[];
    for (final page in doc.pages) {
      onPage?.call(page.pageNumber, doc.pages.length);
      final existing = await page.loadText();
      if (existing != null && existing.fullText.trim().isNotEmpty) continue;
      // About 200 pixels per inch, so small print reads well, but no more
      // than 4000 pixels on the long side, so huge pages fit in memory.
      final scale = math.min(200 / 72, 4000 / math.max(page.width, page.height));
      final width = (page.width * scale).round();
      final height = (page.height * scale).round();
      final rendered = await page.render(fullWidth: width.toDouble(), fullHeight: height.toDouble(), width: width, height: height, backgroundColor: 0xFFFFFFFF);
      if (rendered == null) continue;
      final ui.Image image;
      try {
        image = await rendered.createImage();
      } finally {
        rendered.dispose();
      }
      final ByteData? png;
      try {
        png = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      if (png == null) continue;
      final lines = await readPicture(png.buffer.asUint8List(), size: ui.Size(width.toDouble(), height.toDouble()));
      if (lines.isNotEmpty) edits.add(TextLayerEdit(page.pageNumber, lines: lines));
    }
    return edits;
  }

  Future<void> close() async {
    try {
      await _recognizer.close();
    } catch (_) {}
  }
}

/// Joins lines into paragraphs: a line ending in a sentence break or
/// followed by a gap starts a new paragraph.
String joinLines(List<OcrLine> lines) {
  if (lines.isEmpty) return '';
  final out = StringBuffer(lines.first.text);
  for (var i = 1; i < lines.length; i++) {
    final previous = lines[i - 1];
    final gap = lines[i].rect.top - previous.rect.bottom;
    final newParagraph = gap > previous.rect.height * 0.8 || lines[i].rect.top < previous.rect.top;
    out.write(newParagraph ? '\n\n' : '\n');
    out.write(lines[i].text);
  }
  return out.toString();
}
