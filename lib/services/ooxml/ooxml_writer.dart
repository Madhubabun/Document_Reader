import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Shared plumbing for writing Office Open XML packages.
class OoxmlPackageWriter {
  final _parts = <String, List<int>>{};
  final _overrides = <String, String>{};

  void addXml(String path, String xml, {String? contentType}) {
    _parts[path] = utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n$xml');
    if (contentType != null) _overrides['/$path'] = contentType;
  }

  void addBinary(String path, List<int> bytes) => _parts[path] = bytes;

  /// Adds docProps/core.xml and docProps/app.xml plus their root relationships.
  void addDocProps({String title = ''}) {
    final now = DateTime.now().toUtc().toIso8601String().split('.').first;
    addXml(
      'docProps/core.xml',
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
          '<dc:title>${esc(title)}</dc:title><dc:creator>Doc Reader</dc:creator>'
          '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created>'
          '<dcterms:modified xsi:type="dcterms:W3CDTF">${now}Z</dcterms:modified>'
          '</cp:coreProperties>',
      contentType: 'application/vnd.openxmlformats-package.core-properties+xml',
    );
    addXml(
      'docProps/app.xml',
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Doc Reader</Application></Properties>',
      contentType: 'application/vnd.openxmlformats-officedocument.extended-properties+xml',
    );
  }

  /// Writes `_rels/.rels` pointing at the main part and the doc props.
  void addRootRels(String mainPart) {
    addXml(
      '_rels/.rels',
      rels([
        ('rId1', '$_officeRel/officeDocument', mainPart),
        ('rId2', 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties', 'docProps/core.xml'),
        ('rId3', '$_officeRel/extended-properties', 'docProps/app.xml'),
      ]),
    );
  }

  Uint8List build() {
    final types = StringBuffer(
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '<Default Extension="jpeg" ContentType="image/jpeg"/>',
    );
    _overrides.forEach((part, type) => types.write('<Override PartName="$part" ContentType="$type"/>'));
    types.write('</Types>');
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('[Content_Types].xml', utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n$types')));
    _parts.forEach((path, bytes) => archive.addFile(ArchiveFile.bytes(path, bytes)));
    return ZipEncoder().encodeBytes(archive);
  }

  static const _officeRel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  static String relType(String name) => '$_officeRel/$name';

  static String rels(List<(String id, String type, String target)> entries) {
    final b = StringBuffer('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
    for (final (id, type, target) in entries) {
      b.write('<Relationship Id="$id" Type="$type" Target="${esc(target)}"/>');
    }
    b.write('</Relationships>');
    return b.toString();
  }

  /// Escapes text for XML and drops control characters XML 1.0 forbids.
  static String esc(String s) {
    final b = StringBuffer();
    for (final c in s.runes) {
      switch (c) {
        case 0x26:
          b.write('&amp;');
        case 0x3C:
          b.write('&lt;');
        case 0x3E:
          b.write('&gt;');
        case 0x22:
          b.write('&quot;');
        default:
          if (c == 0x9 || c == 0xA || c == 0xD || (c >= 0x20 && c != 0xFFFE && c != 0xFFFF)) b.writeCharCode(c);
      }
    }
    return b.toString();
  }

  /// `png` or `jpeg` from the file signature.
  static String imageExtension(List<int> bytes) =>
      bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 ? 'jpeg' : 'png';
}
