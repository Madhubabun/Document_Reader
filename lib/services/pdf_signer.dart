import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:pdfrx/pdfrx.dart';

/// A signature image to stamp onto a page.
class SignaturePlacement {
  const SignaturePlacement({required this.pageNumber, required this.rect, required this.rgba, required this.width, required this.height});

  /// 1-based page number.
  final int pageNumber;

  /// Where the image goes, as fractions of the page the way it is shown
  /// (top-left origin, after the page's own rotation).
  final Rect rect;

  /// Straight (not premultiplied) RGBA pixels, [width] x [height].
  final Uint8List rgba;
  final int width;
  final int height;
}

/// Stamps signature images into [pdf] as ordinary page images and returns
/// the new file.
///
/// Files with a classic cross-reference table are saved incrementally: the
/// original bytes stay as they are and the change is appended, the way
/// desktop PDF apps sign. PDFium writes a broken cross-reference stream when
/// it appends to files that use one, so those are rewritten in full.
Future<Uint8List> stampSignatures(Uint8List pdf, List<SignaturePlacement> placements, {String? password}) async {
  final document = await PdfDocument.openData(pdf, passwordProvider: password == null ? null : () => password);
  try {
    await document.useNativeDocumentHandle((handle) {
      final pdfium = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
      final doc = FPDF_DOCUMENT.fromAddress(handle);
      for (final item in placements) {
        _stamp(pdfium, doc, item);
      }
    });
    return await document.encodePdf(incremental: usesXrefTable(pdf));
  } finally {
    await document.dispose();
  }
}

/// True when the last cross-reference section of [pdf] is a classic `xref`
/// table rather than a stream.
bool usesXrefTable(Uint8List pdf) {
  final tail = String.fromCharCodes(pdf.sublist(pdf.length > 2048 ? pdf.length - 2048 : 0));
  final at = tail.lastIndexOf('startxref');
  if (at < 0) return false;
  final offset = int.tryParse(RegExp(r'\d+').firstMatch(tail.substring(at + 9))?.group(0) ?? '');
  if (offset == null || offset < 0 || offset + 4 > pdf.length) return false;
  var i = offset;
  while (i < pdf.length && (pdf[i] == 0x20 || pdf[i] == 0x0A || pdf[i] == 0x0D || pdf[i] == 0x09)) {
    i++;
  }
  return i + 4 <= pdf.length && String.fromCharCodes(pdf.sublist(i, i + 4)) == 'xref';
}

/// Device size used to map fractions to page space; the mapping takes
/// whole pixels, so a large one keeps positions precise.
const _device = 1000000;

void _stamp(PDFium pdfium, FPDF_DOCUMENT doc, SignaturePlacement item) {
  final page = pdfium.FPDF_LoadPage(doc, item.pageNumber - 1);
  if (page == nullptr) throw StateError('Page ${item.pageNumber} could not be opened.');
  final bitmap = pdfium.FPDFBitmap_Create(item.width, item.height, 1);
  try {
    // PDFium bitmaps are BGRA.
    final stride = pdfium.FPDFBitmap_GetStride(bitmap);
    final pixels = pdfium.FPDFBitmap_GetBuffer(bitmap).cast<Uint8>().asTypedList(stride * item.height);
    for (var y = 0; y < item.height; y++) {
      for (var x = 0; x < item.width; x++) {
        final s = (y * item.width + x) * 4;
        final d = y * stride + x * 4;
        pixels[d] = item.rgba[s + 2];
        pixels[d + 1] = item.rgba[s + 1];
        pixels[d + 2] = item.rgba[s];
        pixels[d + 3] = item.rgba[s + 3];
      }
    }

    final image = pdfium.FPDFPageObj_NewImageObj(doc);
    using((arena) {
      final pages = arena<FPDF_PAGE>()..value = page;
      if (pdfium.FPDFImageObj_SetBitmap(pages, 1, image, bitmap) == 0) {
        pdfium.FPDFPageObj_Destroy(image);
        throw StateError('The signature image could not be added.');
      }

      // The image's unit square maps to page space through its matrix. Work
      // out where three of its corners land, so rotated pages come out right.
      final px = arena<Double>();
      final py = arena<Double>();
      (double, double) toPage(double fx, double fy) {
        pdfium.FPDF_DeviceToPage(page, 0, 0, _device, _device, 0, (fx * _device).round(), (fy * _device).round(), px, py);
        return (px.value, py.value);
      }

      final r = item.rect;
      final (x0, y0) = toPage(r.left, r.bottom); // image bottom-left
      final (x1, y1) = toPage(r.right, r.bottom); // bottom-right
      final (x2, y2) = toPage(r.left, r.top); // top-left
      pdfium.FPDFImageObj_SetMatrix(image, x1 - x0, y1 - y0, x2 - x0, y2 - y0, x0, y0);
    });
    pdfium.FPDFPage_InsertObject(page, image);
    if (pdfium.FPDFPage_GenerateContent(page) == 0) throw StateError('The page could not be updated.');
  } finally {
    pdfium.FPDFBitmap_Destroy(bitmap);
    pdfium.FPDF_ClosePage(page);
  }
}
