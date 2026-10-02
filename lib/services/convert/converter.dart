import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../models/doc_file.dart';
import '../ooxml/docx_reader.dart';
import '../ooxml/docx_writer.dart';
import '../ooxml/pptx_reader.dart';
import '../ooxml/pptx_writer.dart';
import '../ooxml/xlsx_reader.dart';
import '../ooxml/xlsx_writer.dart';
import 'office_to_pdf.dart';
import 'pdf_to_office.dart';

/// Raised when a PDF has no selectable text to turn into Word or Excel.
class NoTextException implements Exception {
  const NoTextException();
}

/// Loads the bundled Carlito fonts used for Office -> PDF.
Future<OfficeFonts> loadBundledOfficeFonts() async {
  Future<ByteData> f(String name) => rootBundle.load('assets/fonts/office/Carlito-$name.ttf');
  return OfficeFonts(
    regular: await f('normal-400'),
    bold: await f('normal-700'),
    italic: await f('italic-400'),
    boldItalic: await f('italic-700'),
  );
}

/// Converts the file at [path] to [targetExtension] (pdf, docx, xlsx, pptx)
/// and returns the new file's bytes. Heavy work runs off the UI isolate.
Future<Uint8List> convertFile(
  String path,
  String targetExtension, {
  required Future<OfficeFonts> Function() fonts,
  PdfPasswordProvider? passwordProvider,
  bool keepLayout = true,
}) async {
  final kind = DocKind.fromPath(path);
  final title = p.basenameWithoutExtension(path);
  if (kind != DocKind.pdf) {
    if (targetExtension != 'pdf') throw UnsupportedError('Office files convert to PDF');
    final bytes = await File(path).readAsBytes();
    return compute(_officeToPdf, (kind, bytes, await fonts()));
  }

  final doc = await PdfDocument.openFile(path, passwordProvider: passwordProvider);
  try {
    switch (targetExtension) {
      case 'pptx':
        final pres = await pdfToPresentation(doc);
        return await compute(_writePptx, (pres, title));
      case 'docx' || 'xlsx':
        final content = await extractPdfContent(doc);
        if (content.every((page) => page.lines.isEmpty)) throw const NoTextException();
        return await compute(_writeFromPdfText, (content, targetExtension, title, keepLayout));
      default:
        throw UnsupportedError('Cannot convert PDF to .$targetExtension');
    }
  } finally {
    await doc.dispose();
  }
}

Future<Uint8List> _officeToPdf((DocKind, Uint8List, OfficeFonts) input) {
  final (kind, bytes, fonts) = input;
  return switch (kind) {
    DocKind.word => docxToPdf(DocxReader.read(bytes), fonts),
    DocKind.excel => xlsxToPdf(XlsxReader.read(bytes), fonts),
    DocKind.powerpoint => pptxToPdf(PptxReader.read(bytes), fonts),
    _ => throw UnsupportedError('Not an Office file'),
  };
}

Uint8List _writePptx((PptxPresentation, String) input) => PptxWriter.write(input.$1, title: input.$2);

Uint8List _writeFromPdfText((List<PdfPageContent>, String, String, bool) input) {
  final (content, ext, title, keepLayout) = input;
  return ext == 'docx'
      ? DocxWriter.write(pdfContentToDocx(content, keepPageBreaks: keepLayout), title: title)
      : XlsxWriter.write(pdfContentToXlsx(content), title: title);
}

/// Output file name for a conversion, e.g. `Report.pdf` -> `Report.docx`.
String convertedName(String sourceName, String extension) => '${p.basenameWithoutExtension(sourceName)}.$extension';
