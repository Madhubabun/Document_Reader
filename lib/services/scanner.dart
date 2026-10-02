import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

/// Why a scan gave no pages.
class ScanUnavailable implements Exception {
  const ScanUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Most pages one scan can hold.
const scanPageLimit = 50;

/// Opens the phone's document scanner (Google's ML Kit scanner on Android:
/// finds the page edges, straightens and cleans the pages, and offers
/// black-and-white and colour filters).
///
/// Returns the scanned pages as JPEG bytes, or null when the user backs out.
/// Throws [ScanUnavailable] when the scanner can't run on this phone.
Future<List<Uint8List>?> scanPages() async {
  if (!Platform.isAndroid) {
    throw const ScanUnavailable('The camera scanner works on Android for now. You can still make a PDF from photos.');
  }
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(documentFormats: const {DocumentFormat.jpeg}, pageLimit: scanPageLimit, mode: ScannerMode.full, isGalleryImport: true),
  );
  try {
    final result = await scanner.scanDocument();
    final paths = result.images ?? const <String>[];
    if (paths.isEmpty) return null;
    final pages = <Uint8List>[];
    for (final path in paths) {
      final file = File(path);
      pages.add(await file.readAsBytes());
      // The scanner leaves its pictures in the app's cache; they are copied now.
      try {
        await file.delete();
      } catch (_) {}
    }
    return pages;
  } on PlatformException catch (e) {
    if ((e.message ?? '').toLowerCase().contains('cancel')) return null;
    throw const ScanUnavailable(
        'The scanner could not start. It needs Google Play services, which download it the first time. Check your connection and try again.');
  } on MissingPluginException {
    throw const ScanUnavailable('The camera scanner is not available on this phone. You can still make a PDF from photos.');
  } finally {
    try {
      await scanner.close();
    } catch (_) {}
  }
}
