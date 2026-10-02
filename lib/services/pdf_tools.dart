import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_encrypt.dart';
import 'pdfium_session.dart';

/// A PDF to work on, with its password when it has one.
class PdfSource {
  const PdfSource(this.bytes, {this.password});

  final Uint8List bytes;
  final String? password;
}

/// A page of the source in its new place, turned [quarterTurns] clockwise.
class PagePlan {
  const PagePlan(this.sourcePage, {this.quarterTurns = 0});

  /// 1-based page number in the source.
  final int sourcePage;
  final int quarterTurns;
}

enum CompressLevel {
  light('Light', 'Best quality, smaller saving', 200, 85),
  balanced('Balanced', 'Good for sharing and email', 150, 72),
  strong('Strong', 'Smallest file, fine on screens', 110, 60);

  const CompressLevel(this.label, this.detail, this.dpi, this.quality);

  final String label;
  final String detail;

  /// Pictures are kept at this many pixels per inch of the printed page.
  final int dpi;
  final int quality;
}

class CompressResult {
  const CompressResult(this.bytes, {required this.imagesChanged, required this.pagesSkipped});

  final Uint8List bytes;
  final int imagesChanged;

  /// Pages left as they were because shrinking their pictures changed how
  /// they look.
  final int pagesSkipped;
}

/// Thrown with a message to show as is.
class PdfToolError implements Exception {
  const PdfToolError(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<T> _run<T, M>(({Object? value, String? error}) Function(M) worker, M message) async {
  await PdfrxEntryFunctions.instance.init();
  final result = await PdfrxEntryFunctions.instance.compute(worker, message);
  if (result.error != null) throw PdfToolError(result.error!);
  return result.value as T;
}

String? get _module => Pdfrx.pdfiumModulePath;

/// Opens [bytes] for drawing, trying [password] once.
Future<PdfDocument> openPdfData(Uint8List bytes, String? password) {
  var asked = false;
  return PdfDocument.openData(
    bytes,
    passwordProvider: () {
      if (asked) return null;
      asked = true;
      return password;
    },
    firstAttemptByEmptyPassword: password == null,
  );
}

/// One PDF with the pages of [sources], in order. Form fields become part
/// of the page; passwords are not carried over.
Future<Uint8List> mergePdfs(List<PdfSource> sources) {
  if (sources.length < 2) throw const PdfToolError('Pick at least two PDFs to merge.');
  return _run(_mergeInWorker, (sources: [for (final s in sources) (s.bytes, s.password)], modulePath: _module));
}

/// A PDF for each group of 1-based page numbers. Passwords are not carried
/// over.
Future<List<Uint8List>> splitPdf(PdfSource source, List<List<int>> groups) {
  if (groups.isEmpty || groups.any((g) => g.isEmpty)) throw const PdfToolError('Choose the pages to put in each file.');
  return _run(_splitInWorker, (pdf: source.bytes, password: source.password, groups: groups, modulePath: _module));
}

/// The source with its pages in the order of [plan] (pages not in it are
/// removed) and turned as planned. Everything else, the password included,
/// stays as it was.
Future<Uint8List> organizePdf(PdfSource source, List<PagePlan> plan) {
  if (plan.isEmpty) throw const PdfToolError('A PDF needs at least one page.');
  if (plan.map((p) => p.sourcePage).toSet().length != plan.length) throw const PdfToolError('A page can only appear once.');
  return _run(_organizeInWorker,
      (pdf: source.bytes, password: source.password, plan: [for (final p in plan) (p.sourcePage, p.quarterTurns)], modulePath: _module));
}

/// The source without its password.
Future<Uint8List> unlockPdf(PdfSource source) => _run(_unlockInWorker, (pdf: source.bytes, password: source.password, modulePath: _module));

/// The source protected with [password] (AES-256). A file that already has
/// a password gets the new one instead.
Future<Uint8List> lockPdf(PdfSource source, String password) async {
  if (password.isEmpty) throw const PdfToolError('Type a password.');
  final plain = await _run<Uint8List, ({Uint8List pdf, String? password, String? modulePath})>(_unlockInWorker, (pdf: source.bytes, password: source.password, modulePath: _module));
  try {
    return await Isolate.run(() => encryptPdf(plain, password));
  } on FormatException catch (e) {
    throw PdfToolError('This PDF could not be locked: ${e.message}');
  }
}

/// Whether [password] opens [pdf].
Future<bool> passwordOpens(Uint8List pdf, String password) => _run(_passwordOpensInWorker, (pdf: pdf, password: password, modulePath: _module));

/// Whether [pdf] needs a password to open.
Future<bool> needsPassword(Uint8List pdf) => _run(_needsPasswordInWorker, (pdf: pdf, modulePath: _module));

/// Shrinks the pictures in the source. Each changed page is checked by
/// drawing it before and after; pages that would look different are kept
/// as they were.
Future<CompressResult> compressPdf(PdfSource source, CompressLevel level) async {
  Future<({Uint8List bytes, int changed, List<int> pages})> run(Set<int> skip) async {
    final r = await _run<List<Object>, _CompressMessage>(_compressInWorker,
        (pdf: source.bytes, password: source.password, dpi: level.dpi, quality: level.quality, skip: skip, modulePath: _module));
    return (bytes: r[0] as Uint8List, changed: r[1] as int, pages: (r[2] as List).cast<int>());
  }

  var result = await run(const {});
  if (result.changed == 0) return CompressResult(source.bytes, imagesChanged: 0, pagesSkipped: 0);
  final bad = await _pagesThatDiffer(source, result.bytes, result.pages);
  if (bad.isNotEmpty) {
    result = await run(bad);
    if (result.changed > 0 && (await _pagesThatDiffer(source, result.bytes, result.pages)).isNotEmpty) {
      throw const PdfToolError('This PDF could not be made smaller without changing how it looks.');
    }
  }
  if (result.changed == 0 || result.bytes.length >= source.bytes.length) {
    return CompressResult(source.bytes, imagesChanged: 0, pagesSkipped: bad.length);
  }
  return CompressResult(result.bytes, imagesChanged: result.changed, pagesSkipped: bad.length);
}

/// 1-based numbers of [pages] that look different in [after] than in
/// [source]: drawn small, any area whose colour moved a lot counts.
Future<Set<int>> _pagesThatDiffer(PdfSource source, Uint8List after, List<int> pages) async {
  final a = await openPdfData(source.bytes, source.password);
  final b = await openPdfData(after, source.password);
  try {
    final bad = <int>{};
    for (final n in pages) {
      final pa = a.pages[n - 1];
      final pb = b.pages[n - 1];
      const width = 200;
      final height = math.max(1, (width * pa.height / pa.width).round());
      Future<Uint8List> draw(PdfPage p) async {
        final image = await p.render(fullWidth: width.toDouble(), fullHeight: height.toDouble(), width: width, height: height, backgroundColor: 0xFFFFFFFF);
        if (image == null) throw const PdfToolError('A page could not be checked.');
        final px = Uint8List.fromList(image.pixels);
        image.dispose();
        return px;
      }

      final x = await draw(pa);
      final y = await draw(pb);
      if (!_similar(x, y, width, height)) bad.add(n);
    }
    return bad;
  } finally {
    await a.dispose();
    await b.dispose();
  }
}

/// True when two BGRA renders match apart from small differences: in each
/// 10x10 block, colours differ by under 24 levels on average.
bool _similar(Uint8List x, Uint8List y, int width, int height) {
  const block = 10;
  for (var by = 0; by < height; by += block) {
    for (var bx = 0; bx < width; bx += block) {
      final sum = [0, 0, 0];
      var count = 0;
      for (var yy = by; yy < math.min(by + block, height); yy++) {
        for (var xx = bx; xx < math.min(bx + block, width); xx++) {
          final i = (yy * width + xx) * 4;
          for (var c = 0; c < 3; c++) {
            sum[c] += (x[i + c] - y[i + c]).abs();
          }
          count++;
        }
      }
      for (var c = 0; c < 3; c++) {
        if (sum[c] / count > 24) return false;
      }
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// Worker side

({Object? value, String? error}) _guard(Object? Function(Arena arena) body) {
  try {
    return using((arena) => (value: body(arena), error: null));
  } on PdfToolError catch (e) {
    return (value: null, error: e.message);
  } on StateError catch (e) {
    return (value: null, error: e.message);
  } catch (e) {
    return (value: null, error: '$e');
  }
}

/// A new, empty document that can be saved like a session's.
class _NewDocument {
  _NewDocument(this.pdfium, this.arena) : doc = pdfium.FPDF_CreateNewDocument();

  final PDFium pdfium;
  final Arena arena;
  final FPDF_DOCUMENT doc;

  void importPages(FPDF_DOCUMENT source, List<int> zeroBasedPages) {
    final indices = arena<Int>(zeroBasedPages.length);
    for (var i = 0; i < zeroBasedPages.length; i++) {
      indices[i] = zeroBasedPages[i];
    }
    final at = pdfium.FPDF_GetPageCount(doc);
    if (pdfium.FPDF_ImportPagesByIndex(doc, source, indices, zeroBasedPages.length, at) == 0) {
      throw const PdfToolError('Some pages could not be copied.');
    }
  }

  Uint8List save() => saveDocument(pdfium, doc, arena, flags: 2);

  void close() => pdfium.FPDF_CloseDocument(doc);
}

({Object? value, String? error}) _mergeInWorker(({List<(Uint8List, String?)> sources, String? modulePath}) m) => _guard((arena) {
      final pdfium = getPdfium(modulePath: m.modulePath);
      final out = _NewDocument(pdfium, arena);
      try {
        for (var i = 0; i < m.sources.length; i++) {
          final (bytes, password) = m.sources[i];
          final PdfiumSession session;
          try {
            session = PdfiumSession(pdfium, bytes, password, arena);
          } on StateError catch (e) {
            throw PdfToolError('File ${i + 1}: ${e.message}');
          }
          try {
            if (i == 0) pdfium.FPDF_CopyViewerPreferences(out.doc, session.doc);
            final count = pdfium.FPDF_GetPageCount(session.doc);
            out.importPages(session.doc, [for (var p = 0; p < count; p++) p]);
          } finally {
            session.close();
          }
        }
        return out.save();
      } finally {
        out.close();
      }
    });

({Object? value, String? error}) _splitInWorker(({Uint8List pdf, String? password, List<List<int>> groups, String? modulePath}) m) => _guard((arena) {
      final pdfium = getPdfium(modulePath: m.modulePath);
      final session = PdfiumSession(pdfium, m.pdf, m.password, arena);
      try {
        final count = pdfium.FPDF_GetPageCount(session.doc);
        final files = <Uint8List>[];
        for (final group in m.groups) {
          if (group.any((p) => p < 1 || p > count)) throw PdfToolError('This PDF has $count pages.');
          final out = _NewDocument(pdfium, arena);
          try {
            pdfium.FPDF_CopyViewerPreferences(out.doc, session.doc);
            out.importPages(session.doc, [for (final p in group) p - 1]);
            files.add(out.save());
          } finally {
            out.close();
          }
        }
        return files;
      } finally {
        session.close();
      }
    });

({Object? value, String? error}) _organizeInWorker(({Uint8List pdf, String? password, List<(int, int)> plan, String? modulePath}) m) => _guard((arena) {
      final pdfium = getPdfium(modulePath: m.modulePath);
      final session = PdfiumSession(pdfium, m.pdf, m.password, arena);
      try {
        final doc = session.doc;
        final count = pdfium.FPDF_GetPageCount(doc);
        final wanted = [for (final (page, _) in m.plan) page - 1];
        if (wanted.any((p) => p < 0 || p >= count)) throw PdfToolError('This PDF has $count pages.');
        // Remove pages that are not kept, last first so indexes stay valid.
        final current = [for (var i = 0; i < count; i++) i];
        for (var i = count - 1; i >= 0; i--) {
          if (!wanted.contains(i)) {
            pdfium.FPDFPage_Delete(doc, i);
            current.removeAt(i);
          }
        }
        // Then move each page into place; everything before it is done.
        final index = arena<Int>();
        for (var target = 0; target < wanted.length; target++) {
          final at = current.indexOf(wanted[target]);
          if (at == target) continue;
          index.value = at;
          if (pdfium.FPDF_MovePages(doc, index, 1, target) == 0) throw const PdfToolError('The pages could not be reordered.');
          current.insert(target, current.removeAt(at));
        }
        for (var i = 0; i < m.plan.length; i++) {
          final turns = m.plan[i].$2 % 4;
          if (turns == 0) continue;
          final page = pdfium.FPDF_LoadPage(doc, i);
          if (page == nullptr) throw PdfToolError('Page ${i + 1} could not be opened.');
          pdfium.FPDFPage_SetRotation(page, (pdfium.FPDFPage_GetRotation(page) + turns) % 4);
          pdfium.FPDF_ClosePage(page);
        }
        return session.save(incremental: false);
      } finally {
        session.close();
      }
    });

({Object? value, String? error}) _unlockInWorker(({Uint8List pdf, String? password, String? modulePath}) m) => _guard((arena) {
      final pdfium = getPdfium(modulePath: m.modulePath);
      final session = PdfiumSession(pdfium, m.pdf, m.password, arena);
      try {
        // FPDF_REMOVE_SECURITY writes the whole file without encryption.
        return saveDocument(pdfium, session.doc, arena, flags: 3);
      } finally {
        session.close();
      }
    });

({Object? value, String? error}) _needsPasswordInWorker(({Uint8List pdf, String? modulePath}) m) => _guard((arena) {
      final pdfium = getPdfium(modulePath: m.modulePath);
      try {
        PdfiumSession(pdfium, m.pdf, null, arena).close();
        return false;
      } on StateError catch (e) {
        if (e.message == 'The password is wrong.') return true;
        rethrow;
      }
    });

({Object? value, String? error}) _passwordOpensInWorker(({Uint8List pdf, String password, String? modulePath}) m) => _guard((arena) {
      final pdfium = getPdfium(modulePath: m.modulePath);
      try {
        PdfiumSession(pdfium, m.pdf, m.password, arena).close();
        return true;
      } on StateError catch (e) {
        if (e.message == 'The password is wrong.') return false;
        rethrow;
      }
    });

const _imageObject = 3;

typedef _CompressMessage = ({Uint8List pdf, String? password, int dpi, int quality, Set<int> skip, String? modulePath});

({Object? value, String? error}) _compressInWorker(_CompressMessage m) =>
    _guard((arena) {
      final pdfium = getPdfium(modulePath: m.modulePath);
      final session = PdfiumSession(pdfium, m.pdf, m.password, arena);
      try {
        final doc = session.doc;
        var changed = 0;
        final changedPages = <int>[];
        final count = pdfium.FPDF_GetPageCount(doc);
        for (var n = 1; n <= count; n++) {
          if (m.skip.contains(n)) continue;
          final page = pdfium.FPDF_LoadPage(doc, n - 1);
          if (page == nullptr) continue;
          try {
            var pageChanged = 0;
            final objects = pdfium.FPDFPage_CountObjects(page);
            for (var i = 0; i < objects; i++) {
              final object = pdfium.FPDFPage_GetObject(page, i);
              if (pdfium.FPDFPageObj_GetType(object) != _imageObject) continue;
              if (_shrinkImage(pdfium, doc, page, object, m.dpi, m.quality, arena)) pageChanged++;
            }
            if (pageChanged > 0) {
              if (pdfium.FPDFPage_GenerateContent(page) == 0) throw PdfToolError('Page $n could not be updated.');
              changed += pageChanged;
              changedPages.add(n);
            }
          } finally {
            pdfium.FPDF_ClosePage(page);
          }
        }
        final bytes = changed == 0 ? m.pdf : session.save(incremental: false);
        return <Object>[bytes, changed, changedPages];
      } finally {
        session.close();
      }
    });

/// Re-encodes one picture as a smaller JPEG when that saves space. Leaves
/// see-through pictures, black-and-white scans and small pictures alone.
bool _shrinkImage(PDFium pdfium, FPDF_DOCUMENT doc, FPDF_PAGE page, FPDF_PAGEOBJECT object, int dpi, int quality, Arena arena) {
  // Black-and-white scans use filters that beat JPEG; leave them alone.
  final filters = pdfium.FPDFImageObj_GetImageFilterCount(object);
  for (var f = 0; f < filters; f++) {
    final buffer = arena<Uint8>(64);
    final length = pdfium.FPDFImageObj_GetImageFilter(object, f, buffer.cast(), 64);
    final name = length > 1 ? String.fromCharCodes(buffer.asTypedList(length - 1)) : '';
    if (name == 'JBIG2Decode' || name == 'CCITTFaxDecode') return false;
  }
  final meta = arena<FPDF_IMAGEOBJ_METADATA>();
  if (pdfium.FPDFImageObj_GetImageMetadata(object, page, meta) == 0) return false;
  if (meta.ref.bits_per_pixel <= 1) return false;
  final width = meta.ref.width;
  final height = meta.ref.height;
  if (width * height < 160 * 160) return false;

  // Size on the page, in inches.
  final matrix = arena<FS_MATRIX>();
  if (pdfium.FPDFPageObj_GetMatrix(object, matrix) == 0) return false;
  final shownWidth = math.sqrt(matrix.ref.a * matrix.ref.a + matrix.ref.b * matrix.ref.b) / 72;
  final shownHeight = math.sqrt(matrix.ref.c * matrix.ref.c + matrix.ref.d * matrix.ref.d) / 72;
  if (shownWidth <= 0 || shownHeight <= 0) return false;
  final scale = math.min(1.0, math.max(shownWidth * dpi / width, shownHeight * dpi / height));
  final rawSize = pdfium.FPDFImageObj_GetImageDataRaw(object, nullptr, 0);
  // A picture already at the target size and stored compactly stays.
  if (scale > 0.9 && rawSize < width * height * 0.25) return false;

  // Skip pictures with see-through parts: JPEG can't keep them.
  final rendered = pdfium.FPDFImageObj_GetRenderedBitmap(doc, page, object);
  if (rendered == nullptr) return false;
  try {
    if (pdfium.FPDFBitmap_GetFormat(rendered) == FPDFBitmap_BGRA) {
      final w = pdfium.FPDFBitmap_GetWidth(rendered);
      final h = pdfium.FPDFBitmap_GetHeight(rendered);
      final stride = pdfium.FPDFBitmap_GetStride(rendered);
      final px = pdfium.FPDFBitmap_GetBuffer(rendered).cast<Uint8>().asTypedList(stride * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (px[y * stride + x * 4 + 3] != 255) return false;
        }
      }
    }
  } finally {
    pdfium.FPDFBitmap_Destroy(rendered);
  }

  final bitmap = pdfium.FPDFImageObj_GetBitmap(object);
  if (bitmap == nullptr) return false;
  final Uint8List jpeg;
  try {
    final format = pdfium.FPDFBitmap_GetFormat(bitmap);
    final w = pdfium.FPDFBitmap_GetWidth(bitmap);
    final h = pdfium.FPDFBitmap_GetHeight(bitmap);
    final stride = pdfium.FPDFBitmap_GetStride(bitmap);
    final px = pdfium.FPDFBitmap_GetBuffer(bitmap).cast<Uint8>().asTypedList(stride * h);
    final gray = format == FPDFBitmap_Gray;
    final step = switch (format) { FPDFBitmap_Gray => 1, FPDFBitmap_BGR => 3, FPDFBitmap_BGRx || FPDFBitmap_BGRA => 4, _ => 0 };
    if (step == 0) return false;
    var picture = img.Image(width: w, height: h, numChannels: gray ? 1 : 3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * stride + x * step;
        if (gray) {
          picture.setPixelRgb(x, y, px[i], px[i], px[i]);
        } else {
          picture.setPixelRgb(x, y, px[i + 2], px[i + 1], px[i]);
        }
      }
    }
    if (scale < 0.9) {
      picture = img.copyResize(picture, width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()), interpolation: img.Interpolation.average);
    }
    jpeg = img.encodeJpg(picture, quality: quality);
  } finally {
    pdfium.FPDFBitmap_Destroy(bitmap);
  }
  if (jpeg.length > rawSize * 0.85) return false;

  // Hand the JPEG to PDFium through a file-access callback.
  int getBlock(Pointer<Void> param, int position, Pointer<UnsignedChar> buffer, int size) {
    if (position + size > jpeg.length) return 0;
    buffer.cast<Uint8>().asTypedList(size).setRange(0, size, jpeg, position);
    return 1;
  }

  final callable = NativeCallable<Int Function(Pointer<Void>, UnsignedLong, Pointer<UnsignedChar>, UnsignedLong)>.isolateLocal(getBlock, exceptionalReturn: 0);
  try {
    final access = arena<FPDF_FILEACCESS>();
    access.ref.m_FileLen = jpeg.length;
    access.ref.m_GetBlock = callable.nativeFunction;
    access.ref.m_Param = nullptr;
    final pages = arena<FPDF_PAGE>()..value = page;
    return pdfium.FPDFImageObj_LoadJpegFileInline(pages, 1, object, access) != 0;
  } finally {
    callable.close();
  }
}
