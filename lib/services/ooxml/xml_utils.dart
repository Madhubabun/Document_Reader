import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Helpers for reading Office Open XML packages without caring about
/// namespace prefixes (files from different producers use different ones).
extension OoxmlElement on XmlElement {
  Iterable<XmlElement> kids(String local) => childElements.where((e) => e.name.local == local);

  XmlElement? kid(String local) {
    for (final e in childElements) {
      if (e.name.local == local) return e;
    }
    return null;
  }

  Iterable<XmlElement> deep(String local) => descendantElements.where((e) => e.name.local == local);

  String? attr(String local) {
    for (final a in attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }

  /// The relationship id (`r:id`), which must not be confused with a plain
  /// `id` attribute on the same element (e.g. `<p:sldId id="256" r:id="rId2"/>`).
  String? get relId {
    for (final a in attributes) {
      if (a.name.local == 'id' && a.name.prefix != null) return a.value;
    }
    return null;
  }

  /// OOXML boolean toggles like `<w:b/>` or `<w:b w:val="false"/>`.
  bool get isOn {
    final v = attr('val');
    return v == null || !(v == '0' || v == 'false' || v == 'off' || v == 'none');
  }
}

/// Read access to the parts of an Office package, either straight from a
/// file ([OoxmlPackage]) or from a package being edited.
abstract interface class PackageSource {
  XmlDocument? xml(String name);
  List<int>? bytes(String name);

  /// Relationship id -> target path (resolved relative to [partPath]).
  Map<String, String> relationships(String partPath);

  /// Target of the first relationship whose type ends with [typeSuffix].
  String? relationshipOfType(String partPath, String typeSuffix);
}

class OoxmlPackage implements PackageSource {
  OoxmlPackage(List<int> bytes) : _archive = ZipDecoder().decodeBytes(bytes);

  final Archive _archive;

  bool has(String name) => _archive.findFile(name) != null;

  @override
  List<int>? bytes(String name) => _archive.findFile(name)?.content;

  @override
  XmlDocument? xml(String name) {
    final data = bytes(name);
    if (data == null) return null;
    return XmlDocument.parse(utf8.decode(data, allowMalformed: true));
  }

  @override
  Map<String, String> relationships(String partPath) {
    final slash = partPath.lastIndexOf('/');
    final dir = slash < 0 ? '' : partPath.substring(0, slash);
    final file = partPath.substring(slash + 1);
    final doc = xml('${dir.isEmpty ? '' : '$dir/'}_rels/$file.rels');
    if (doc == null) return const {};
    final result = <String, String>{};
    for (final rel in doc.rootElement.kids('Relationship')) {
      final id = rel.attr('Id');
      final target = rel.attr('Target');
      if (id == null || target == null || rel.attr('TargetMode') == 'External') continue;
      result[id] = resolvePath(dir, target);
    }
    return result;
  }

  /// Target of the first relationship whose type ends with [typeSuffix]
  /// (e.g. `/slideLayout`).
  @override
  String? relationshipOfType(String partPath, String typeSuffix) {
    final slash = partPath.lastIndexOf('/');
    final dir = slash < 0 ? '' : partPath.substring(0, slash);
    final doc = xml('${dir.isEmpty ? '' : '$dir/'}_rels/${partPath.substring(slash + 1)}.rels');
    if (doc == null) return null;
    for (final rel in doc.rootElement.kids('Relationship')) {
      final target = rel.attr('Target');
      if (target != null && (rel.attr('Type') ?? '').endsWith(typeSuffix)) return resolvePath(dir, target);
    }
    return null;
  }

  static String resolvePath(String baseDir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = baseDir.isEmpty ? <String>[] : baseDir.split('/');
    for (final seg in target.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg != '.' && seg.isNotEmpty) {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }
}

class OoxmlFormatException implements Exception {
  OoxmlFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}
