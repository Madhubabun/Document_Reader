import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../ooxml/docx_reader.dart';
import '../ooxml/pptx_reader.dart';
import '../ooxml/xlsx_reader.dart';

/// A run of text on one line, in page points from the top-left corner.
class PdfTextSegment {
  const PdfTextSegment(this.text, this.left, this.right);

  final String text;
  final double left;
  final double right;
}

/// One visual line of text: segments separated by wide gaps (columns).
class PdfTextLine {
  const PdfTextLine({required this.segments, required this.top, required this.bottom});

  final List<PdfTextSegment> segments;
  final double top;
  final double bottom;

  double get height => bottom - top;
  String get text => segments.map((s) => s.text).join('\t');
}

class PdfPageContent {
  const PdfPageContent({required this.width, required this.height, required this.lines});

  final double width;
  final double height;
  final List<PdfTextLine> lines;
}

/// Reads the text of every page, grouped into lines and column segments.
Future<List<PdfPageContent>> extractPdfContent(PdfDocument doc) async {
  final pages = <PdfPageContent>[];
  for (final page in doc.pages) {
    final text = await page.loadStructuredText();
    final boxes = <_Box>[];
    for (final f in text.fragments) {
      final t = f.text.replaceAll(RegExp(r'[\r\n]'), '');
      if (t.isEmpty) continue;
      final b = f.bounds;
      boxes.add(_Box(t, b.left, page.height - b.top, b.right, page.height - b.bottom));
    }
    pages.add(PdfPageContent(width: page.width, height: page.height, lines: _groupLines(boxes)));
  }
  return pages;
}

class _Box {
  _Box(this.text, this.left, this.top, this.right, this.bottom);

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get height => bottom - top;
}

/// Groups word boxes into lines by vertical overlap, then splits each line
/// into segments wherever the horizontal gap looks like a column break.
List<PdfTextLine> _groupLines(List<_Box> boxes) {
  final sorted = boxes.where((b) => b.text.trim().isNotEmpty).toList()
    ..sort((a, b) => (a.top + a.bottom).compareTo(b.top + b.bottom));
  final rows = <List<_Box>>[];
  for (final box in sorted) {
    final mid = (box.top + box.bottom) / 2;
    final row = rows.isEmpty ? null : rows.last;
    if (row != null) {
      final top = row.map((b) => b.top).reduce((a, b) => a < b ? a : b);
      final bottom = row.map((b) => b.bottom).reduce((a, b) => a > b ? a : b);
      if (mid > top && mid < bottom) {
        row.add(box);
        continue;
      }
    }
    rows.add([box]);
  }
  final lines = <PdfTextLine>[];
  for (final row in rows) {
    row.sort((a, b) => a.left.compareTo(b.left));
    final h = row.map((b) => b.height).reduce((a, b) => a > b ? a : b);
    final segments = <PdfTextSegment>[];
    var text = StringBuffer(row.first.text);
    var left = row.first.left;
    var right = row.first.right;
    for (final box in row.skip(1)) {
      final gap = box.left - right;
      final afterBullet = _bulletGlyph.hasMatch(text.toString().trim());
      if (gap > h * 1.6 && !afterBullet) {
        segments.add(PdfTextSegment(text.toString().trim(), left, right));
        text = StringBuffer(box.text);
        left = box.left;
      } else {
        final s = text.toString();
        if ((gap > h * 0.12 || afterBullet) && !s.endsWith(' ') && !box.text.startsWith(' ')) text.write(' ');
        text.write(box.text);
      }
      if (box.right > right) right = box.right;
    }
    segments.add(PdfTextSegment(text.toString().trim(), left, right));
    lines.add(PdfTextLine(
      segments: segments.where((s) => s.text.isNotEmpty).toList(),
      top: row.map((b) => b.top).reduce((a, b) => a < b ? a : b),
      bottom: row.map((b) => b.bottom).reduce((a, b) => a > b ? a : b),
    ));
  }
  return lines.where((l) => l.segments.isNotEmpty).toList();
}

/// Builds word boxes for tests and other callers that already have positions.
List<PdfTextLine> groupLinesFrom(List<(String text, double left, double top, double right, double bottom)> words) =>
    _groupLines([for (final w in words) _Box(w.$1, w.$2, w.$3, w.$4, w.$5)]);

double _median(List<double> values) {
  if (values.isEmpty) return 11;
  final s = [...values]..sort();
  return s[s.length ~/ 2];
}

final _bulletGlyph = RegExp(r'^[•◦▪■●○‣]$');
final _bullet = RegExp(r'^[•◦▪■●○‣\-–]\s+');

/// PDF text -> Word. Lines are merged back into paragraphs, larger lines
/// become headings, and each PDF page starts a new Word page.
DocxDocument pdfContentToDocx(List<PdfPageContent> pages, {bool keepPageBreaks = true}) {
  final body = _median([for (final p in pages) for (final l in p.lines) l.height]);
  final blocks = <DocxBlock>[];
  for (var i = 0; i < pages.length; i++) {
    if (i > 0 && keepPageBreaks) blocks.add(const DocxPageBreak());
    final lines = pages[i].lines;
    var buffer = StringBuffer();
    PdfTextLine? prev;
    int? level;
    bool? bulletPara;

    void flush() {
      if (prev == null || buffer.isEmpty) return;
      final h = prev.height;
      final ratio = h / body;
      final heading = ratio > 1.7 ? 1 : (ratio > 1.35 ? 2 : 0);
      final text = buffer.toString().trim();
      final size = (h / 1.2 * 2).round() / 2;
      blocks.add(DocxParagraph(
        runs: [DocxRun(text, bold: heading > 0, fontSizePt: heading > 0 ? size.clamp(12, 48).toDouble() : null)],
        headingLevel: heading,
        listLevel: bulletPara == true ? level : null,
      ));
      buffer = StringBuffer();
    }

    for (final line in lines) {
      var text = line.text;
      final isBullet = _bullet.hasMatch(text);
      if (isBullet) text = text.replaceFirst(_bullet, '');
      final p = prev;
      final continues = p != null &&
          buffer.isNotEmpty &&
          !isBullet &&
          line.top - p.bottom < body * 0.7 &&
          (line.height - p.height).abs() < body * 0.25 &&
          !text.contains('\t') &&
          !p.text.contains('\t');
      if (continues) {
        final s = buffer.toString();
        if (s.endsWith('-') && !s.endsWith(' -')) {
          buffer = StringBuffer(s.substring(0, s.length - 1));
        } else {
          buffer.write(' ');
        }
        buffer.write(text);
      } else {
        flush();
        buffer.write(text);
        bulletPara = isBullet;
        level = isBullet ? 0 : null;
      }
      prev = line;
    }
    flush();
  }
  final first = pages.isEmpty ? null : pages.first;
  final page = first == null
      ? DocxPageSetup.a4
      : DocxPageSetup(width: (first.width * 20).round(), height: (first.height * 20).round());
  return DocxDocument(blocks, page: page);
}

final _number = RegExp(r'^-?\(?[$€£¥₹]?\s?\d{1,3}(,\d{3})*(\.\d+)?\)?$|^-?[$€£¥₹]?\d+(\.\d+)?$');

/// PDF text -> Excel. Each page becomes a sheet; segments line up into
/// columns by their left edge, and plain numbers are stored as numbers.
XlsxWorkbook pdfContentToXlsx(List<PdfPageContent> pages) {
  final sheets = <XlsxSheet>[];
  for (var i = 0; i < pages.length; i++) {
    final lines = pages[i].lines;
    final lefts = [for (final l in lines) for (final s in l.segments) s.left]..sort();
    final columns = <double>[];
    for (final x in lefts) {
      if (columns.isEmpty || x - columns.last > 14) columns.add(x);
    }
    int columnOf(double x) {
      var best = 0;
      for (var c = 0; c < columns.length; c++) {
        if (columns[c] <= x + 14) best = c;
      }
      return best;
    }

    final cells = <(int, int), XlsxCell>{};
    for (var r = 0; r < lines.length; r++) {
      var lastCol = -1;
      for (final seg in lines[r].segments) {
        var c = columnOf(seg.left);
        if (c <= lastCol) c = lastCol + 1;
        lastCol = c;
        final raw = seg.text;
        if (_number.hasMatch(raw)) {
          final negative = raw.startsWith('-') || (raw.contains('(') && raw.contains(')'));
          final digits = raw.replaceAll(RegExp(r'[^\d.]'), '');
          final n = double.tryParse(digits);
          if (n != null) {
            final v = negative ? -n : n;
            cells[(r, c)] = XlsxCell(v == v.roundToDouble() && !digits.contains('.') ? v.toInt().toString() : v.toString(), isNumber: true);
            continue;
          }
        }
        cells[(r, c)] = XlsxCell(raw);
      }
    }
    sheets.add(XlsxSheet('Page ${i + 1}', cells));
  }
  return XlsxWorkbook(sheets);
}

/// PDF -> PowerPoint: each page becomes a slide holding a crisp picture of
/// the page, so layout, fonts and graphics look exactly like the PDF.
Future<PptxPresentation> pdfToPresentation(PdfDocument doc, {int targetWidthPx = 1920}) async {
  if (doc.pages.isEmpty) return const PptxPresentation(slideWidth: PptxReader.defaultWidth, slideHeight: 6858000, slides: []);
  final first = doc.pages.first;
  // PowerPoint allows slides from 1 to 56 inches on each side.
  var scale = 12700.0;
  final longest = first.width > first.height ? first.width : first.height;
  if (longest * scale > 51206400) scale = 51206400 / longest;
  final slideW = (first.width * scale).round();
  final slideH = (first.height * scale).round();
  final slides = <PptxSlide>[];
  for (final page in doc.pages) {
    final px = targetWidthPx / page.width;
    final image = await page.render(
      fullWidth: page.width * px,
      fullHeight: page.height * px,
      backgroundColor: 0xFFFFFFFF,
    );
    if (image == null) continue;
    final png = encodeBgraPng(image.pixels, image.width, image.height);
    image.dispose();
    // Fit the page inside the slide, centred, keeping its aspect ratio.
    final fit = (slideW / page.width < slideH / page.height) ? slideW / page.width : slideH / page.height;
    final w = (page.width * fit).round();
    final h = (page.height * fit).round();
    slides.add(PptxSlide([
      PptxShape(kind: PptxShapeKind.picture, rect: EmuRect((slideW - w) ~/ 2, (slideH - h) ~/ 2, w, h), imageBytes: png),
    ], background: 'FFFFFF'));
  }
  return PptxPresentation(slideWidth: slideW, slideHeight: slideH, slides: slides);
}

Uint8List encodeBgraPng(Uint8List bgra, int width, int height) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: bgra.buffer,
    bytesOffset: bgra.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
  return img.encodePng(image, level: 6);
}
