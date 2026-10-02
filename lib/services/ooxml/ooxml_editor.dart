import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'ooxml_writer.dart';
import 'xml_utils.dart';

/// What the reader screens need from an editor to save and undo.
abstract interface class DocumentEditor {
  /// True when there are edits since opening or the last [markSaved].
  bool get hasChanges;
  bool get canUndo;
  bool undo();

  /// The edited file.
  Uint8List save();

  /// Call after the bytes from [save] were written.
  void markSaved();
}

/// Thrown when an edit would damage something the app can't safely update.
class EditRefused implements Exception {
  const EditRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An Office package opened for editing.
///
/// XML parts are parsed on first use and kept; only the parts marked dirty
/// are written back by [save]. Every other part is copied byte for byte, so
/// a file keeps everything the app doesn't understand.
class EditablePackage {
  EditablePackage(List<int> bytes) : _archive = ZipDecoder().decodeBytes(bytes);

  static const relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const maxUndo = 40;

  final Archive _archive;
  final _docs = <String, XmlDocument>{};
  final _dirty = <String>{};
  final _removed = <String>{};
  final _undo = <(Map<String, String>, Set<String>, Set<String>)>[];
  final _bytes = <String, Uint8List>{};
  int _version = 0;
  int _savedVersion = 0;

  bool get hasChanges => _version != _savedVersion;
  bool get canUndo => _undo.isNotEmpty;
  Iterable<String> get partNames => _archive.files.where((f) => f.isFile).map((f) => f.name);

  bool has(String path) => !_removed.contains(path) && (_docs.containsKey(path) || _archive.findFile(path) != null);

  XmlDocument? xml(String path) {
    final cached = _docs[path];
    if (cached != null) return cached;
    if (_removed.contains(path)) return null;
    final file = _archive.findFile(path);
    if (file == null) return null;
    return _docs[path] = XmlDocument.parse(utf8.decode(file.content as List<int>, allowMalformed: true));
  }

  /// Raw bytes of a part, the same list every time (for pictures).
  Uint8List? bytes(String path) {
    final cached = _bytes[path];
    if (cached != null) return cached;
    final file = _archive.findFile(path);
    if (file == null) return null;
    final content = file.content as List<int>;
    return _bytes[path] = content is Uint8List ? content : Uint8List.fromList(content);
  }

  void put(String path, XmlDocument doc) {
    _docs[path] = doc;
    _removed.remove(path);
    _dirty.add(path);
  }

  void touch(String path) => _dirty.add(path);

  void remove(String path) {
    _removed.add(path);
    _docs.remove(path);
  }

  static String relsPath(String part) {
    final slash = part.lastIndexOf('/');
    return '${part.substring(0, slash + 1)}_rels/${part.substring(slash + 1)}.rels';
  }

  /// Relationship id -> `<Relationship>` element.
  Map<String, XmlElement> relationships(String part) => {
        for (final r in xml(relsPath(part))?.rootElement.kids('Relationship') ?? const <XmlElement>[])
          if (r.attr('Id') != null) r.attr('Id')!: r,
      };

  /// Relationship id -> resolved part path, for internal targets.
  Map<String, String> targets(String part) => {
        for (final e in relationships(part).entries)
          if (e.value.attr('TargetMode') != 'External') e.key: target(part, e.value),
      };

  String target(String part, XmlElement rel) {
    final slash = part.lastIndexOf('/');
    return OoxmlPackage.resolvePath(slash < 0 ? '' : part.substring(0, slash), rel.attr('Target') ?? '');
  }

  String? targetOfType(String part, String typeSuffix) {
    for (final r in relationships(part).values) {
      if ((r.attr('Type') ?? '').endsWith(typeSuffix)) return target(part, r);
    }
    return null;
  }

  String addRelationship(String part, String type, String target) {
    final path = relsPath(part);
    var doc = xml(path);
    if (doc == null) {
      doc = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>');
      put(path, doc);
    }
    final ids = doc.rootElement.kids('Relationship').map((r) => r.attr('Id')).toSet();
    var i = ids.length + 1;
    while (ids.contains('rId$i')) {
      i++;
    }
    doc.rootElement.children.add(XmlElement(XmlName.parts('Relationship'), [
      XmlAttribute(XmlName.parts('Id'), 'rId$i'),
      XmlAttribute(XmlName.parts('Type'), type),
      XmlAttribute(XmlName.parts('Target'), target),
    ]));
    touch(path);
    return 'rId$i';
  }

  void addOverride(String partName, String contentType) {
    final types = xml('[Content_Types].xml')!;
    types.rootElement.children.add(XmlElement(XmlName.parts('Override'), [
      XmlAttribute(XmlName.parts('PartName'), partName),
      XmlAttribute(XmlName.parts('ContentType'), contentType),
    ]));
    touch('[Content_Types].xml');
  }

  /// Saves the current state of every parsed part for [undo].
  void checkpoint() {
    _version++;
    _undo.add(({for (final e in _docs.entries) e.key: e.value.toXmlString()}, {..._dirty}, {..._removed}));
    if (_undo.length > maxUndo) _undo.removeAt(0);
  }

  /// Marks a change that has no undo step of its own (it belongs to the
  /// last [checkpoint]).
  void changed() => _version++;

  bool undo() {
    if (_undo.isEmpty) return false;
    final (docs, dirty, removed) = _undo.removeLast();
    _version++;
    _docs
      ..clear()
      ..addAll({for (final e in docs.entries) e.key: XmlDocument.parse(e.value)});
    _dirty
      ..clear()
      ..addAll(dirty);
    _removed
      ..clear()
      ..addAll(removed);
    return true;
  }

  Uint8List save() {
    final out = Archive();
    final written = <String>{};
    for (final file in _archive.files) {
      if (!file.isFile || _removed.contains(file.name)) continue;
      final doc = _dirty.contains(file.name) ? _docs[file.name] : null;
      out.addFile(ArchiveFile.bytes(file.name, doc != null ? utf8.encode(serialize(doc)) : file.content as List<int>));
      written.add(file.name);
    }
    for (final path in _dirty) {
      if (written.contains(path) || _removed.contains(path)) continue;
      final doc = _docs[path];
      if (doc != null) out.addFile(ArchiveFile.bytes(path, utf8.encode(serialize(doc))));
    }
    return Uint8List.fromList(ZipEncoder().encodeBytes(out));
  }

  void markSaved() => _savedVersion = _version;

  static String serialize(XmlDocument doc) {
    final text = doc.toXmlString();
    return text.startsWith('<?xml') ? text : '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n$text';
  }

  static String escape(String text) => OoxmlPackageWriter.esc(text);
}

/// Inserts [child] into [parent] so that children stay in the schema
/// [order] (OOXML property elements are sequences, and Word rejects files
/// whose properties are out of order). Replaces an existing element with
/// the same name.
void putInOrder(XmlElement parent, XmlElement child, List<String> order) {
  final name = child.name.local;
  for (final existing in parent.childElements.toList()) {
    if (existing.name.local == name) {
      parent.children[parent.children.indexOf(existing)] = child;
      return;
    }
  }
  final rank = order.indexOf(name);
  for (final existing in parent.childElements) {
    final r = order.indexOf(existing.name.local);
    if (r > rank) {
      parent.children.insert(parent.children.indexOf(existing), child);
      return;
    }
  }
  parent.children.add(child);
}

void removeKids(XmlElement parent, String local) => parent.children.removeWhere((n) => n is XmlElement && n.name.local == local);
