import 'dart:io';

import 'package:flutter/services.dart';

/// A file another app opened with or shared to this one, copied into the
/// app's cache.
class IncomingFile {
  const IncomingFile({required this.path, required this.name, required this.type});

  final String path;
  final String name;

  /// MIME type as the sending app reported it (may be empty).
  final String type;

  bool get isImage => type.startsWith('image/') || RegExp(r'\.(jpe?g|png|webp|heic|heif|gif|bmp)$', caseSensitive: false).hasMatch(name);

  /// Deletes the cached copy.
  Future<void> discard() async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

/// Files arriving from other apps ("Open with" and "Share" on Android).
class IncomingFiles {
  IncomingFiles(this.onFiles);

  static const _channel = MethodChannel('doc_reader/incoming');

  final Future<void> Function(List<IncomingFile> files) onFiles;
  bool _taking = false;

  /// Starts listening and picks up anything that arrived before.
  void start() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'available') await _take();
    });
    _take();
  }

  void stop() {
    if (Platform.isAndroid) _channel.setMethodCallHandler(null);
  }

  Future<void> _take() async {
    if (_taking) return;
    _taking = true;
    try {
      while (true) {
        final List<Object?>? raw;
        try {
          raw = await _channel.invokeListMethod<Object?>('take');
        } on MissingPluginException {
          return;
        }
        final files = [
          for (final item in raw ?? const [])
            if (item is Map)
              IncomingFile(path: '${item['path']}', name: '${item['name']}', type: '${item['type'] ?? ''}'),
        ];
        if (files.isEmpty) return;
        await onFiles(files);
      }
    } finally {
      _taking = false;
    }
  }
}
