import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:pdfrx/pdfrx.dart';

/// A change to write into a PDF. Positions are fractions of the page the way
/// it is shown (top-left origin, after the page's own rotation).
sealed class PdfEdit {
  const PdfEdit(this.pageNumber);

  /// 1-based page number.
  final int pageNumber;
}

enum MarkupKind { highlight, underline, strikeout }

/// Highlight, underline or strike out text, one rectangle per line.
class MarkupEdit extends PdfEdit {
  const MarkupEdit(super.pageNumber, {required this.kind, required this.lines, required this.color});

  final MarkupKind kind;
  final List<Rect> lines;

  /// 0xAARRGGBB.
  final int color;
}

/// Freehand pen or marker strokes.
class InkEdit extends PdfEdit {
  const InkEdit(super.pageNumber, {required this.strokes, required this.color, required this.width, this.opacity = 1});

  final List<List<Offset>> strokes;

  /// 0xAARRGGBB.
  final int color;

  /// Line width as a fraction of the page width.
  final double width;
  final double opacity;
}

/// An image, such as a drawn signature, placed on a page.
class ImageEdit extends PdfEdit {
  const ImageEdit(super.pageNumber, {required this.rect, required this.rgba, required this.width, required this.height});

  final Rect rect;

  /// Straight (not premultiplied) RGBA pixels, [width] x [height].
  final Uint8List rgba;
  final int width;
  final int height;
}

/// A new value for a form field found by [readFormFields].
class FieldEdit extends PdfEdit {
  const FieldEdit(super.pageNumber, {required this.annotIndex, this.text, this.checked, this.option});

  final int annotIndex;

  /// For text fields.
  final String? text;

  /// For checkboxes and radio buttons.
  final bool? checked;

  /// For combo boxes and list boxes.
  final int? option;
}

enum FormFieldKind { text, checkbox, radio, choice, other }

/// A fillable field (one widget of it; radio groups have one per button).
class PdfFormField {
  const PdfFormField({
    required this.pageNumber,
    required this.annotIndex,
    required this.kind,
    required this.name,
    required this.value,
    required this.checked,
    required this.options,
    required this.selected,
    required this.rect,
    required this.readOnly,
    required this.multiline,
  });

  final int pageNumber;
  final int annotIndex;
  final FormFieldKind kind;
  final String name;
  final String value;
  final bool checked;
  final List<String> options;

  /// Index of the selected option, or -1.
  final int selected;

  /// Fractions of the shown page.
  final Rect rect;
  final bool readOnly;
  final bool multiline;
}

/// Writes [edits] into [pdf] and returns the new file.
///
/// Files with a classic cross-reference table are saved incrementally: the
/// original bytes stay as they are and the changes are appended, the way
/// desktop PDF apps sign and annotate. PDFium writes a broken
/// cross-reference stream when it appends to files that use one, so those
/// are rewritten in full.
Future<Uint8List> applyPdfEdits(Uint8List pdf, List<PdfEdit> edits, {String? password}) async {
  await PdfrxEntryFunctions.instance.init();
  final result = await PdfrxEntryFunctions.instance.compute(
    _applyInWorker,
    (pdf: pdf, edits: edits, password: password, modulePath: Pdfrx.pdfiumModulePath, incremental: usesXrefTable(pdf)),
  );
  if (result.error != null) throw StateError(result.error!);
  return result.bytes!;
}

/// Lists the fillable fields of [pdf].
Future<List<PdfFormField>> readFormFields(Uint8List pdf, {String? password}) async {
  await PdfrxEntryFunctions.instance.init();
  final result = await PdfrxEntryFunctions.instance.compute(
    _readFieldsInWorker,
    (pdf: pdf, password: password, modulePath: Pdfrx.pdfiumModulePath),
  );
  if (result.error != null) throw StateError(result.error!);
  return result.fields!;
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

// ---------------------------------------------------------------------------
// Everything below runs on pdfrx's PDFium worker isolate, where PDFium is
// initialised and no other PDFium call can run at the same time.

/// Device size used to map fractions to page space; the mapping takes
/// whole pixels, so a large one keeps positions precise.
const _device = 1000000;

/// An open document with its form environment.
class _Session {
  _Session(this.pdfium, Uint8List pdf, String? password, this.arena) {
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

  Uint8List save({required bool incremental}) {
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
      if (pdfium.FPDF_SaveAsCopy(doc, fw, incremental ? 1 : 2) == 0) throw StateError('The PDF could not be saved.');
    } finally {
      callable.close();
    }
    return out.takeBytes();
  }

  void close() {
    if (form != nullptr) pdfium.FPDFDOC_ExitFormFillEnvironment(form);
    calloc.free(_formInfo);
    pdfium.FPDF_CloseDocument(doc);
    malloc.free(_buffer);
  }
}

typedef _ApplyMessage = ({Uint8List pdf, List<PdfEdit> edits, String? password, String? modulePath, bool incremental});

({Uint8List? bytes, String? error}) _applyInWorker(_ApplyMessage m) {
  try {
    return using((arena) {
      final session = _Session(getPdfium(modulePath: m.modulePath), m.pdf, m.password, arena);
      try {
        // Fields first: the others add annotations, which would shift the
        // indexes that identify fields.
        final byPage = <int, List<PdfEdit>>{};
        for (final e in m.edits) {
          byPage.putIfAbsent(e.pageNumber, () => []).add(e);
        }
        for (final entry in byPage.entries) {
          final page = session.openPage(entry.key);
          try {
            for (final e in entry.value.whereType<FieldEdit>()) {
              _fillField(session, page, e);
            }
            if (session.form != nullptr) session.pdfium.FORM_ForceToKillFocus(session.form);
            var annotated = false;
            for (final e in entry.value) {
              switch (e) {
                case MarkupEdit():
                  _addMarkup(session, page, e);
                  annotated = true;
                case InkEdit():
                  _addInk(session, page, e);
                  annotated = true;
                case ImageEdit():
                  _addImage(session, page, e);
                case FieldEdit():
                  break;
              }
            }
            if (annotated) _generateAppearances(session, page);
          } finally {
            session.closePage(page);
          }
        }
        return (bytes: session.save(incremental: m.incremental), error: null);
      } finally {
        session.close();
      }
    });
  } catch (e) {
    return (bytes: null, error: '$e');
  }
}

typedef _ReadMessage = ({Uint8List pdf, String? password, String? modulePath});

({List<PdfFormField>? fields, String? error}) _readFieldsInWorker(_ReadMessage m) {
  try {
    return using((arena) {
      final session = _Session(getPdfium(modulePath: m.modulePath), m.pdf, m.password, arena);
      final pdfium = session.pdfium;
      final fields = <PdfFormField>[];
      try {
        if (session.form == nullptr) return (fields: fields, error: null);
        final pages = pdfium.FPDF_GetPageCount(session.doc);
        for (var n = 1; n <= pages; n++) {
          final page = session.openPage(n);
          try {
            final count = pdfium.FPDFPage_GetAnnotCount(page);
            for (var i = 0; i < count; i++) {
              final annot = pdfium.FPDFPage_GetAnnot(page, i);
              if (annot == nullptr) continue;
              try {
                if (pdfium.FPDFAnnot_GetSubtype(annot) != FPDF_ANNOT_WIDGET) continue;
                final type = pdfium.FPDFAnnot_GetFormFieldType(session.form, annot);
                final kind = switch (type) {
                  FPDF_FORMFIELD_TEXTFIELD => FormFieldKind.text,
                  FPDF_FORMFIELD_CHECKBOX => FormFieldKind.checkbox,
                  FPDF_FORMFIELD_RADIOBUTTON => FormFieldKind.radio,
                  FPDF_FORMFIELD_COMBOBOX || FPDF_FORMFIELD_LISTBOX => FormFieldKind.choice,
                  _ => FormFieldKind.other,
                };
                if (kind == FormFieldKind.other) continue;
                final flags = pdfium.FPDFAnnot_GetFormFieldFlags(session.form, annot);
                final rect = arena<FS_RECTF>();
                if (pdfium.FPDFAnnot_GetRect(annot, rect) == 0) continue;
                final options = <String>[];
                var selected = -1;
                if (kind == FormFieldKind.choice) {
                  final n = pdfium.FPDFAnnot_GetOptionCount(session.form, annot);
                  for (var o = 0; o < n; o++) {
                    options.add(_wide((buf, len) => pdfium.FPDFAnnot_GetOptionLabel(session.form, annot, o, buf, len), arena));
                    if (selected < 0 && pdfium.FPDFAnnot_IsOptionSelected(session.form, annot, o) != 0) selected = o;
                  }
                }
                fields.add(PdfFormField(
                  pageNumber: n,
                  annotIndex: i,
                  kind: kind,
                  name: _wide((buf, len) => pdfium.FPDFAnnot_GetFormFieldName(session.form, annot, buf, len), arena),
                  value: _wide((buf, len) => pdfium.FPDFAnnot_GetFormFieldValue(session.form, annot, buf, len), arena),
                  checked: (kind == FormFieldKind.checkbox || kind == FormFieldKind.radio) && pdfium.FPDFAnnot_IsChecked(session.form, annot) != 0,
                  options: options,
                  selected: selected,
                  rect: session.toFraction(page, rect.ref.left, rect.ref.top, rect.ref.right, rect.ref.bottom),
                  readOnly: flags & FPDF_FORMFLAG_READONLY != 0,
                  multiline: flags & FPDF_FORMFLAG_TEXT_MULTILINE != 0,
                ));
              } finally {
                pdfium.FPDFPage_CloseAnnot(annot);
              }
            }
          } finally {
            session.closePage(page);
          }
        }
        return (fields: fields, error: null);
      } finally {
        session.close();
      }
    });
  } catch (e) {
    return (fields: null, error: '$e');
  }
}

/// Reads a UTF-16 string from a PDFium getter that reports its size in bytes.
String _wide(int Function(Pointer<UnsignedShort> buffer, int length) get, Arena arena) {
  final bytes = get(nullptr, 0);
  if (bytes <= 2) return '';
  final buffer = arena<UnsignedShort>(bytes ~/ 2);
  get(buffer, bytes);
  return String.fromCharCodes(buffer.cast<Uint16>().asTypedList(bytes ~/ 2 - 1));
}

Pointer<UnsignedShort> _toWide(String text, Arena arena) {
  final units = text.codeUnits;
  final p = arena<UnsignedShort>(units.length + 1);
  final list = p.cast<Uint16>().asTypedList(units.length + 1);
  list.setAll(0, units);
  list[units.length] = 0;
  return p;
}

/// Fills a field the way a person would, so PDFium updates its value and
/// redraws it with the field's own font and size.
void _fillField(_Session s, FPDF_PAGE page, FieldEdit e) {
  final pdfium = s.pdfium;
  if (s.form == nullptr) throw StateError('This PDF has no form.');
  final annot = pdfium.FPDFPage_GetAnnot(page, e.annotIndex);
  if (annot == nullptr) throw StateError('A form field could not be found.');
  try {
    final type = pdfium.FPDFAnnot_GetFormFieldType(s.form, annot);
    if (e.text != null && type == FPDF_FORMFIELD_TEXTFIELD) {
      if (pdfium.FORM_SetFocusedAnnot(s.form, annot) == 0) throw StateError('A text field could not be filled in.');
      pdfium.FORM_SelectAllText(s.form, page);
      pdfium.FORM_ReplaceSelection(s.form, page, _toWide(e.text!.replaceAll('\r\n', '\n'), s.arena));
      pdfium.FORM_ForceToKillFocus(s.form);
    } else if (e.checked != null && (type == FPDF_FORMFIELD_CHECKBOX || type == FPDF_FORMFIELD_RADIOBUTTON)) {
      final checked = pdfium.FPDFAnnot_IsChecked(s.form, annot) != 0;
      // Radio buttons can only be switched on; choosing another button in
      // the group switches this one off.
      if (checked != e.checked && (type == FPDF_FORMFIELD_CHECKBOX || e.checked!)) {
        final rect = s.arena<FS_RECTF>();
        pdfium.FPDFAnnot_GetRect(annot, rect);
        final x = (rect.ref.left + rect.ref.right) / 2;
        final y = (rect.ref.top + rect.ref.bottom) / 2;
        pdfium.FORM_OnLButtonDown(s.form, page, 0, x, y);
        pdfium.FORM_OnLButtonUp(s.form, page, 0, x, y);
        pdfium.FORM_ForceToKillFocus(s.form);
      }
    } else if (e.option != null && (type == FPDF_FORMFIELD_COMBOBOX || type == FPDF_FORMFIELD_LISTBOX)) {
      if (pdfium.FORM_SetFocusedAnnot(s.form, annot) == 0) throw StateError('A choice field could not be filled in.');
      pdfium.FORM_SetIndexSelected(s.form, page, e.option!, 1);
      pdfium.FORM_ForceToKillFocus(s.form);
    }
  } finally {
    pdfium.FPDFPage_CloseAnnot(annot);
  }
}

void _setColor(PDFium pdfium, FPDF_ANNOTATION annot, int argb) {
  pdfium.FPDFAnnot_SetColor(annot, FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color, (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF);
}

void _addMarkup(_Session s, FPDF_PAGE page, MarkupEdit e) {
  final pdfium = s.pdfium;
  final subtype = switch (e.kind) {
    MarkupKind.highlight => FPDF_ANNOT_HIGHLIGHT,
    MarkupKind.underline => FPDF_ANNOT_UNDERLINE,
    MarkupKind.strikeout => FPDF_ANNOT_STRIKEOUT,
  };
  final annot = pdfium.FPDFPage_CreateAnnot(page, subtype);
  if (annot == nullptr) throw StateError('The markup could not be added.');
  try {
    _setColor(pdfium, annot, e.color);
    pdfium.FPDFAnnot_SetFlags(annot, FPDF_ANNOT_FLAG_PRINT);
    var bounds = <double>[double.infinity, double.infinity, -double.infinity, -double.infinity];
    final strokes = StringBuffer();
    for (final line in e.lines) {
      // Quad points go top-left, top-right, bottom-left, bottom-right, as
      // Acrobat writes them.
      final corners = [line.topLeft, line.topRight, line.bottomLeft, line.bottomRight].map((c) => s.toPage(page, c)).toList();
      final quad = s.arena<FS_QUADPOINTSF>();
      quad.ref
        ..x1 = corners[0].$1
        ..y1 = corners[0].$2
        ..x2 = corners[1].$1
        ..y2 = corners[1].$2
        ..x3 = corners[2].$1
        ..y3 = corners[2].$2
        ..x4 = corners[3].$1
        ..y4 = corners[3].$2;
      pdfium.FPDFAnnot_AppendAttachmentPoints(annot, quad);
      if (e.kind != MarkupKind.highlight) {
        // A line along the text, a little above the bottom for underlines
        // and through the middle for strikeouts. Worked out from the quad
        // rather than page axes, so text on rotated pages is crossed out
        // along its length.
        final (blx, bly) = corners[2];
        final (brx, bry) = corners[3];
        final (tlx, tly) = corners[0];
        final up = Offset(tlx - blx, tly - bly);
        final height = up.distance;
        final at = e.kind == MarkupKind.underline ? 0.08 : 0.45;
        final width = (height / 14).clamp(0.5, 4.0);
        String n(double v) => v.toStringAsFixed(2);
        strokes.write('${n(width)} w ${n(blx + up.dx * at)} ${n(bly + up.dy * at)} m ${n(brx + up.dx * at)} ${n(bry + up.dy * at)} l S\n');
      }
      for (final (x, y) in corners) {
        bounds = [bounds[0] < x ? bounds[0] : x, bounds[1] < y ? bounds[1] : y, bounds[2] > x ? bounds[2] : x, bounds[3] > y ? bounds[3] : y];
      }
    }
    final rect = s.arena<FS_RECTF>();
    rect.ref
      ..left = bounds[0]
      ..bottom = bounds[1]
      ..right = bounds[2]
      ..top = bounds[3];
    pdfium.FPDFAnnot_SetRect(annot, rect);
    if (strokes.isNotEmpty) {
      // PDFium's own appearance for these follows the page axes, which is
      // wrong on rotated pages, so write the lines directly.
      String c(int shift) => (((e.color >> shift) & 0xFF) / 255).toStringAsFixed(3);
      final stream = 'q ${c(16)} ${c(8)} ${c(0)} RG 1 J\n$strokes' 'Q';
      if (pdfium.FPDFAnnot_SetAP(annot, FPDF_ANNOT_APPEARANCEMODE_NORMAL, _toWide(stream, s.arena)) == 0) {
        throw StateError('The markup could not be drawn.');
      }
    }
  } finally {
    pdfium.FPDFPage_CloseAnnot(annot);
  }
}

void _addInk(_Session s, FPDF_PAGE page, InkEdit e) {
  final pdfium = s.pdfium;
  final annot = pdfium.FPDFPage_CreateAnnot(page, FPDF_ANNOT_INK);
  if (annot == nullptr) throw StateError('The drawing could not be added.');
  try {
    _setColor(pdfium, annot, (e.color & 0xFFFFFF) | ((e.opacity * 255).round() << 24));
    pdfium.FPDFAnnot_SetFlags(annot, FPDF_ANNOT_FLAG_PRINT);
    // Width in points: the page's shown width is the distance between two
    // corners in page space.
    final (ax, ay) = s.toPage(page, Offset.zero);
    final (bx, by) = s.toPage(page, const Offset(1, 0));
    final pageWidth = Offset(bx - ax, by - ay).distance;
    final width = e.width * pageWidth;
    pdfium.FPDFAnnot_SetBorder(annot, 0, 0, width);
    var bounds = <double>[double.infinity, double.infinity, -double.infinity, -double.infinity];
    for (final stroke in e.strokes) {
      if (stroke.isEmpty) continue;
      final points = s.arena<FS_POINTF>(stroke.length);
      for (var i = 0; i < stroke.length; i++) {
        final (x, y) = s.toPage(page, stroke[i]);
        points[i]
          ..x = x
          ..y = y;
        bounds = [bounds[0] < x ? bounds[0] : x, bounds[1] < y ? bounds[1] : y, bounds[2] > x ? bounds[2] : x, bounds[3] > y ? bounds[3] : y];
      }
      if (pdfium.FPDFAnnot_AddInkStroke(annot, points, stroke.length) < 0) throw StateError('The drawing could not be added.');
    }
    final rect = s.arena<FS_RECTF>();
    rect.ref
      ..left = bounds[0] - width
      ..bottom = bounds[1] - width
      ..right = bounds[2] + width
      ..top = bounds[3] + width;
    pdfium.FPDFAnnot_SetRect(annot, rect);
  } finally {
    pdfium.FPDFPage_CloseAnnot(annot);
  }
}

/// PDFium writes appearance streams for new markup and ink annotations when
/// it first draws them; drawing the page once stores them in the file, so
/// readers that don't generate their own still show the annotations.
void _generateAppearances(_Session s, FPDF_PAGE page) {
  final bitmap = s.pdfium.FPDFBitmap_Create(4, 4, 0);
  try {
    s.pdfium.FPDF_RenderPageBitmap(bitmap, page, 0, 0, 4, 4, 0, FPDF_ANNOT);
  } finally {
    s.pdfium.FPDFBitmap_Destroy(bitmap);
  }
}

void _addImage(_Session s, FPDF_PAGE page, ImageEdit e) {
  final pdfium = s.pdfium;
  final bitmap = pdfium.FPDFBitmap_Create(e.width, e.height, 1);
  try {
    // PDFium bitmaps are BGRA.
    final stride = pdfium.FPDFBitmap_GetStride(bitmap);
    final pixels = pdfium.FPDFBitmap_GetBuffer(bitmap).cast<Uint8>().asTypedList(stride * e.height);
    for (var y = 0; y < e.height; y++) {
      for (var x = 0; x < e.width; x++) {
        final from = (y * e.width + x) * 4;
        final to = y * stride + x * 4;
        pixels[to] = e.rgba[from + 2];
        pixels[to + 1] = e.rgba[from + 1];
        pixels[to + 2] = e.rgba[from];
        pixels[to + 3] = e.rgba[from + 3];
      }
    }
    final image = pdfium.FPDFPageObj_NewImageObj(s.doc);
    final pages = s.arena<FPDF_PAGE>()..value = page;
    if (pdfium.FPDFImageObj_SetBitmap(pages, 1, image, bitmap) == 0) {
      pdfium.FPDFPageObj_Destroy(image);
      throw StateError('The image could not be added.');
    }
    // The image's unit square maps to page space through its matrix. Work
    // out where three of its corners land, so rotated pages come out right.
    final (x0, y0) = s.toPage(page, e.rect.bottomLeft);
    final (x1, y1) = s.toPage(page, e.rect.bottomRight);
    final (x2, y2) = s.toPage(page, e.rect.topLeft);
    pdfium.FPDFImageObj_SetMatrix(image, x1 - x0, y1 - y0, x2 - x0, y2 - y0, x0, y0);
    pdfium.FPDFPage_InsertObject(page, image);
    if (pdfium.FPDFPage_GenerateContent(page) == 0) throw StateError('The page could not be updated.');
  } finally {
    pdfium.FPDFBitmap_Destroy(bitmap);
  }
}
