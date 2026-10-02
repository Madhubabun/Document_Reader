import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Signatures the user drew, kept as transparent PNGs for reuse.
class SignatureStore {
  SignatureStore(this.dir);

  final Directory dir;

  /// Newest first.
  Future<List<File>> list() async {
    if (!await dir.exists()) return [];
    final files = (await dir.list().toList()).whereType<File>().where((f) => f.path.endsWith('.png')).toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<File> add(Uint8List png) async {
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'signature-${DateTime.now().microsecondsSinceEpoch}.png'));
    await file.writeAsBytes(png, flush: true);
    return file;
  }

  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
  }
}
