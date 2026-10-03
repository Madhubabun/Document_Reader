import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ocr.dart';
import 'pdf_tools.dart';

/// A short, plain sentence about [e] to show people.
/// The technical detail goes to the debug log.
String errorText(Object e) {
  debugPrint('$e');
  return switch (e) {
    PdfToolError(:final message) => message,
    OcrUnavailable(:final message) => message,
    StateError(:final message) => message,
    PdfPasswordException() => 'The password is not right.',
    PdfException() => 'The file is damaged, or is not a PDF this app can read.',
    FileSystemException() => 'The file is missing or unreadable.',
    FormatException() => 'The file is damaged, or in a format this app can\'t read.',
    PlatformException(code: 'already_active') => 'Another picker is already open.',
    PlatformException(:final message?) when message.isNotEmpty => message,
    _ => 'Something went wrong. Please try again.',
  };
}
