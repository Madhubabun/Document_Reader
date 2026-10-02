import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/doc_file.dart';

/// Recent files and favorites, persisted locally.
///
/// Imported files are copied into the app's own documents folder so they stay
/// readable after the picker's temporary copy is cleaned up.
class LibraryStore extends ChangeNotifier {
  LibraryStore(this._prefs, this._libraryDir);

  static const _key = 'library.v1';
  static const maxRecents = 200;

  final SharedPreferences _prefs;
  final Directory _libraryDir;
  List<DocFile> _files = [];

  List<DocFile> get files => List.unmodifiable(_files);

  List<DocFile> get favorites => _files.where((f) => f.favorite).toList();

  void load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
      _files = list.map(DocFile.fromJson).where((f) => File(f.path).existsSync()).toList()
        ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
    } catch (_) {
      _files = [];
    }
    notifyListeners();
  }

  Future<void> _save() => _prefs.setString(_key, jsonEncode(_files.map((f) => f.toJson()).toList()));

  /// Copies [bytes] into the library under [name] and returns the stored file.
  Future<DocFile> importBytes(String name, List<int> bytes) async {
    await _libraryDir.create(recursive: true);
    final target = _uniquePath(p.basename(name));
    await File(target).writeAsBytes(bytes, flush: true);
    final file = DocFile(
      path: target,
      name: p.basename(target),
      sizeBytes: bytes.length,
      openedAt: DateTime.now(),
    );
    _files.insert(0, file);
    if (_files.length > maxRecents) _files.removeRange(maxRecents, _files.length);
    notifyListeners();
    await _save();
    return file;
  }

  String _uniquePath(String name) {
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var candidate = p.join(_libraryDir.path, name);
    var i = 2;
    while (File(candidate).existsSync()) {
      candidate = p.join(_libraryDir.path, '$base ($i)$ext');
      i++;
    }
    return candidate;
  }

  Future<void> markOpened(DocFile file) async {
    final i = _files.indexWhere((f) => f.path == file.path);
    if (i < 0) return;
    final updated = _files.removeAt(i).copyWith(openedAt: DateTime.now());
    _files.insert(0, updated);
    notifyListeners();
    await _save();
  }

  Future<void> toggleFavorite(DocFile file) async {
    final i = _files.indexWhere((f) => f.path == file.path);
    if (i < 0) return;
    _files[i] = _files[i].copyWith(favorite: !_files[i].favorite);
    notifyListeners();
    await _save();
  }

  Future<void> remove(DocFile file, {bool deleteFile = true}) async {
    _files.removeWhere((f) => f.path == file.path);
    notifyListeners();
    await _save();
    if (deleteFile && p.isWithin(_libraryDir.path, file.path)) {
      final f = File(file.path);
      if (await f.exists()) await f.delete();
    }
  }

  DocFile? byPath(String path) {
    for (final f in _files) {
      if (f.path == path) return f;
    }
    return null;
  }
}
