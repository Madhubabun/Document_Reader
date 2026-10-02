import 'dart:io';

import 'package:doc_reader/models/conversion.dart';
import 'package:doc_reader/models/doc_file.dart';
import 'package:doc_reader/services/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('library_test');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('import copies the file, dedupes names and persists', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs, dir);
    final a = await store.importBytes('Report.pdf', [1, 2, 3]);
    final b = await store.importBytes('Report.pdf', [4, 5]);
    expect(a.name, 'Report.pdf');
    expect(b.name, 'Report (2).pdf');
    expect(File(b.path).readAsBytesSync(), [4, 5]);
    expect(store.files.first.path, b.path);

    final reloaded = LibraryStore(prefs, dir)..load();
    expect(reloaded.files.map((f) => f.name), ['Report (2).pdf', 'Report.pdf']);
  });

  test('favorites, reopen order and delete', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs, dir);
    final a = await store.importBytes('a.docx', [1]);
    await store.importBytes('b.xlsx', [2]);
    await store.toggleFavorite(a);
    expect(store.favorites.single.name, 'a.docx');
    await store.markOpened(store.byPath(a.path)!);
    expect(store.files.first.name, 'a.docx');
    await store.remove(a);
    expect(store.files.map((f) => f.name), ['b.xlsx']);
    expect(File(a.path).existsSync(), isFalse);
  });

  test('saving an edit keeps earlier versions and updates the entry', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs, dir);
    final a = await store.importBytes('sheet.xlsx', [1]);
    for (var i = 2; i < 15; i++) {
      await store.saveEdited(store.byPath(a.path)!, List.filled(i, i));
    }
    expect(File(a.path).readAsBytesSync(), List.filled(14, 14));
    expect(store.byPath(a.path)!.sizeBytes, 14);
    final versions = await store.versionsOf(a);
    expect(versions, hasLength(LibraryStore.keepVersions));
    expect(versions.first.readAsBytesSync(), List.filled(13, 13));
    expect(File('${a.path}.saving').existsSync(), isFalse);
  });

  test('load drops entries whose file is gone', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs, dir);
    final a = await store.importBytes('gone.pptx', [1]);
    File(a.path).deleteSync();
    expect((LibraryStore(prefs, dir)..load()).files, isEmpty);
  });

  test('file kinds and legacy detection', () {
    DocFile f(String name) => DocFile(path: '/x/$name', name: name, sizeBytes: 0, openedAt: DateTime(2026));
    expect(f('a.PDF').kind, DocKind.pdf);
    expect(f('a.docx').kind, DocKind.word);
    expect(f('a.xls').kind, DocKind.excel);
    expect(f('a.pptx').kind, DocKind.powerpoint);
    expect(f('a.txt').kind, DocKind.other);
    expect(f('a.doc').isLegacyBinary, isTrue);
    expect(f('a.docx').isLegacyBinary, isFalse);
  });

  test('conversion matrix: PDF to and from each Office format', () {
    expect(conversionTargets(DocKind.pdf).map((t) => t.extension), ['docx', 'xlsx', 'pptx']);
    for (final k in [DocKind.word, DocKind.excel, DocKind.powerpoint]) {
      expect(conversionTargets(k).single.extension, 'pdf');
    }
    expect(conversionTargets(DocKind.other), isEmpty);
  });

  test('formatting helpers', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes((2.4 * 1024 * 1024).round()), '2.4 MB');
    final now = DateTime(2026, 10, 2, 12);
    expect(formatRelative(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(formatRelative(now.subtract(const Duration(days: 1)), now: now), 'Yesterday');
  });
}
