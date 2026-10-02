import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/doc_file.dart';
import 'signature_store.dart';

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

  /// Signatures saved for signing PDFs.
  late final signatures = SignatureStore(Directory(p.join(_libraryDir.path, '.signatures')));

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
      // Its earlier versions go too, so a new file with the same name
      // doesn't inherit them.
      final versions = _versionsDir(file);
      if (await versions.exists()) await versions.delete(recursive: true);
    }
  }

  /// How many earlier versions of each edited file are kept.
  static const keepVersions = 10;

  Directory _versionsDir(DocFile file) => Directory(p.join(_libraryDir.path, '.versions', p.basename(file.path)));

  /// Replaces [file]'s contents with [bytes] after keeping a copy of the
  /// current contents in `.versions`, so an edit can always be rolled back.
  /// The new contents are written to a temporary file first and then moved
  /// into place, so an interrupted save never leaves a half-written file.
  ///
  /// [dropHistory] deletes the earlier versions instead, for changes such as
  /// adding a password, where an old copy would undo the point.
  Future<DocFile> saveEdited(DocFile file, List<int> bytes, {bool dropHistory = false}) async {
    final target = File(file.path);
    if (dropHistory) {
      final dir = _versionsDir(file);
      if (await dir.exists()) await dir.delete(recursive: true);
    } else if (await target.exists()) {
      final dir = _versionsDir(file);
      await dir.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      await target.copy(p.join(dir.path, '$stamp${p.extension(file.path)}'));
      final versions = (await dir.list().toList()).whereType<File>().toList()..sort((a, b) => b.path.compareTo(a.path));
      for (final old in versions.skip(keepVersions)) {
        await old.delete();
      }
    }
    final temp = File('${file.path}.saving');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    final updated = file.copyWith(sizeBytes: bytes.length, openedAt: DateTime.now());
    final i = _files.indexWhere((f) => f.path == file.path);
    if (i >= 0) {
      _files.removeAt(i);
      _files.insert(0, updated);
      notifyListeners();
      await _save();
    }
    return updated;
  }

  /// Earlier versions of [file], newest first.
  Future<List<File>> versionsOf(DocFile file) async {
    final dir = _versionsDir(file);
    if (!await dir.exists()) return [];
    return (await dir.list().toList()).whereType<File>().toList()..sort((a, b) => b.path.compareTo(a.path));
  }

  DocFile? byPath(String path) {
    for (final f in _files) {
      if (f.path == path) return f;
    }
    return null;
  }
}

/// A file name (without extension) safe on Android and iOS: characters the
/// file system rejects become dashes, a typed [extension] is dropped, and an
/// empty result falls back to [fallback].
String safeBaseName(String raw, {required String fallback, String? extension}) {
  var name = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '-');
  if (extension != null) name = name.replaceAll(RegExp('\\.${RegExp.escape(extension)}\$', caseSensitive: false), '');
  // Leading dots would hide the file.
  name = name.replaceFirst(RegExp(r'^[.\s]+'), '').trim();
  // File names are limited to 255 bytes; leave room for " (2)" and the
  // extension. Cut between characters, never inside one.
  if (utf8.encode(name).length > 180) {
    final kept = StringBuffer();
    var bytes = 0;
    for (final rune in name.runes) {
      final char = String.fromCharCode(rune);
      bytes += utf8.encode(char).length;
      if (bytes > 180) break;
      kept.write(char);
    }
    name = kept.toString().trim();
  }
  return name.isEmpty ? fallback : name;
}
