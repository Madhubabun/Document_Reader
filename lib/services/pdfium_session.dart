import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

// Everything here runs on pdfrx's PDFium worker isolate, where PDFium is
// initialised and no other PDFium call can run at the same time.

/// Device size used to map fractions to page space; the mapping takes
/// whole pixels, so a large one keeps positions precise.
const _device = 1000000;

/// An open document with its form environment.
class PdfiumSession {
  PdfiumSession(this.pdfium, Uint8List pdf, String? password, this.arena) {
    _buffer = malloc<Uint8>(pdf.length)..asTypedList(pdf.length).setAll(0, pdf);
    doc = pdfium.FPDF_LoadMemDocument64(_buffer.cast(), pdf.length, password == null ? nullptr : password.toNativeUtf8(allocator: arena).cast());
    if (doc == nullptr) {
      malloc.free(_buffer);
      throw StateError(pdfium.FPDF_GetLastError() == 4 ? 'The password is wrong.' : 'The PDF could not be opened.');
    }
    _formInfo = calloc<FPDF_FORMFILLINFO>()..ref.version = 1;
    form = pdfium.FPDFDOC_InitFormFillEnvironment(doc, _formInfo);
  }

  final PDFium pdfium;
  final Arena arena;
  late final Pointer<Uint8> _buffer;
  late final FPDF_DOCUMENT doc;
  late final Pointer<FPDF_FORMFILLINFO> _formInfo;
  late final FPDF_FORMHANDLE form;

  FPDF_PAGE openPage(int pageNumber) {
    final page = pdfium.FPDF_LoadPage(doc, pageNumber - 1);
    if (page == nullptr) throw StateError('Page $pageNumber could not be opened.');
    if (form != nullptr) pdfium.FORM_OnAfterLoadPage(page, form);
    return page;
  }

  void closePage(FPDF_PAGE page) {
    if (form != nullptr) pdfium.FORM_OnBeforeClosePage(page, form);
    pdfium.FPDF_ClosePage(page);
  }

  /// Maps a fraction of the shown page to page space.
  (double, double) toPage(FPDF_PAGE page, Offset f) {
    final px = arena<Double>();
    final py = arena<Double>();
    pdfium.FPDF_DeviceToPage(page, 0, 0, _device, _device, 0, (f.dx * _device).round(), (f.dy * _device).round(), px, py);
    return (px.value, py.value);
  }

  /// Maps a page-space rectangle to fractions of the shown page.
  Rect toFraction(FPDF_PAGE page, double left, double top, double right, double bottom) {
    final dx = arena<Int>();
    final dy = arena<Int>();
    pdfium.FPDF_PageToDevice(page, 0, 0, _device, _device, 0, left, top, dx, dy);
    final a = Offset(dx.value / _device, dy.value / _device);
    pdfium.FPDF_PageToDevice(page, 0, 0, _device, _device, 0, right, bottom, dx, dy);
    final b = Offset(dx.value / _device, dy.value / _device);
    return Rect.fromPoints(a, b);
  }

  Uint8List save({required bool incremental}) => saveDocument(pdfium, doc, arena, flags: incremental ? 1 : 2);

  void close() {
    if (form != nullptr) pdfium.FPDFDOC_ExitFormFillEnvironment(form);
    calloc.free(_formInfo);
    pdfium.FPDF_CloseDocument(doc);
    malloc.free(_buffer);
  }
}

/// Reads a UTF-16 string from a PDFium getter that reports its size in bytes.
String readWide(int Function(Pointer<UnsignedShort> buffer, int length) get, Arena arena) {
  final bytes = get(nullptr, 0);
  if (bytes <= 2) return '';
  final buffer = arena<UnsignedShort>(bytes ~/ 2);
  get(buffer, bytes);
  return String.fromCharCodes(buffer.cast<Uint16>().asTypedList(bytes ~/ 2 - 1));
}

Pointer<UnsignedShort> toWide(String text, Arena arena) {
  final units = text.codeUnits;
  final p = arena<UnsignedShort>(units.length + 1);
  final list = p.cast<Uint16>().asTypedList(units.length + 1);
  list.setAll(0, units);
  list[units.length] = 0;
  return p;
}


/// Writes [doc] with FPDF_SaveAsCopy: [flags] 1 appends the changes, 2
/// rewrites the file, 3 rewrites it without its password.
Uint8List saveDocument(PDFium pdfium, FPDF_DOCUMENT doc, Arena arena, {required int flags}) {
  final out = BytesBuilder(copy: true);
  int write(Pointer<FPDF_FILEWRITE> self, Pointer<Void> data, int size) {
    out.add(data.cast<Uint8>().asTypedList(size));
    return 1;
  }

  final callable = NativeCallable<Int Function(Pointer<FPDF_FILEWRITE>, Pointer<Void>, UnsignedLong)>.isolateLocal(write, exceptionalReturn: 0);
  try {
    final fw = arena<FPDF_FILEWRITE>();
    fw.ref.version = 1;
    fw.ref.WriteBlock = callable.nativeFunction;
    if (pdfium.FPDF_SaveAsCopy(doc, fw, flags) == 0) throw StateError('The PDF could not be saved.');
  } finally {
    callable.close();
  }
  return out.takeBytes();
}
