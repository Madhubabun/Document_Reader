import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Protects a PDF with a password using AES-256 (the PDF 2.0 standard
/// security handler, revision 6), which Acrobat, Chrome, Edge, Preview and
/// Android viewers open.
///
/// [plain] must be an unencrypted PDF with a classic cross-reference table
/// and no object streams, as PDFium writes when it rewrites a file. Anything
/// else throws a [FormatException] rather than risk a broken file.
Uint8List encryptPdf(Uint8List plain, String password, {Random? random}) {
  final rng = random ?? Random.secure();
  final parser = _Parser(plain);
  final trailer = parser.trailer();
  if (trailer.containsKey('Encrypt')) throw const FormatException('the file is already encrypted');
  final root = trailer['Root'];
  if (root is! _Ref) throw const FormatException('no document catalog');
  final info = trailer['Info'];

  final key = _bytes(rng, 32);
  final security = _SecurityHandler(password, key, rng);
  final objects = parser.objects();
  final out = BytesBuilder(copy: false);
  void write(String s) => out.add(latin1.encode(s));
  // Binary marker after the header, as the spec recommends.
  out.add([...latin1.encode('%PDF-1.7\n%'), 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
  final offsets = <int, (int, int)>{};
  var maxNumber = 0;
  for (final (number, _) in objects.keys) {
    if (number > maxNumber) maxNumber = number;
  }
  final encryptNumber = maxNumber + 1;
  final sorted = objects.keys.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  for (final id in sorted) {
    if (objects[id]!.leftover) continue;
    offsets[id.$1] = (out.length, id.$2);
    write('${id.$1} ${id.$2} obj\n');
    out.add(parser.encryptObject(objects[id]!, security, isCatalog: id.$1 == root.number && id.$2 == root.generation));
    write('\nendobj\n');
  }
  offsets[encryptNumber] = (out.length, 0);
  write('$encryptNumber 0 obj\n${security.dictionary()}\nendobj\n');

  final xref = out.length;
  final size = encryptNumber + 1;
  final table = StringBuffer('xref\n0 $size\n0000000000 65535 f\r\n');
  for (var n = 1; n < size; n++) {
    final entry = offsets[n];
    table.write(entry == null ? '0000000000 65535 f\r\n' : '${entry.$1.toString().padLeft(10, '0')} ${entry.$2.toString().padLeft(5, '0')} n\r\n');
  }
  write(table.toString());
  final oldId = trailer['ID'];
  final first = oldId is List && oldId.isNotEmpty && oldId.first is _Str ? (oldId.first as _Str).bytes : _bytes(rng, 16);
  write('trailer\n<</Size $size/Root ${root.number} ${root.generation} R'
      '${info is _Ref ? '/Info ${info.number} ${info.generation} R' : ''}'
      '/Encrypt $encryptNumber 0 R/ID[<${_hex(first)}><${_hex(_bytes(rng, 16))}>]>>\nstartxref\n$xref\n%%EOF\n');
  return out.toBytes();
}

Uint8List _bytes(Random rng, int n) => Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// -----------------------------------------------------------------------------
// Standard security handler, revision 6 (ISO 32000-2, 7.6.4.3.3)

class _SecurityHandler {
  _SecurityHandler(String password, this.key, this.rng) {
    var pw = utf8.encode(password);
    if (pw.length > 127) pw = pw.sublist(0, 127);
    final userValidation = _bytes(rng, 8);
    final userKeySalt = _bytes(rng, 8);
    u = Uint8List.fromList([...hardenedHash(pw, userValidation, const []), ...userValidation, ...userKeySalt]);
    ue = _aesCbcNoPad(hardenedHash(pw, userKeySalt, const []), key);
    final ownerValidation = _bytes(rng, 8);
    final ownerKeySalt = _bytes(rng, 8);
    o = Uint8List.fromList([...hardenedHash(pw, ownerValidation, u), ...ownerValidation, ...ownerKeySalt]);
    oe = _aesCbcNoPad(hardenedHash(pw, ownerKeySalt, u), key);
    final perms = Uint8List(16)
      ..buffer.asByteData().setInt32(0, permissions, Endian.little)
      ..setAll(4, [0xFF, 0xFF, 0xFF, 0xFF])
      ..setAll(8, latin1.encode('Tadb'))
      ..setAll(12, _bytes(rng, 4));
    final ecb = AESEngine()..init(true, KeyParameter(key));
    this.perms = Uint8List(16);
    ecb.processBlock(perms, 0, this.perms, 0);
  }

  /// Every permission granted: the password only stops opening.
  static const permissions = -4;

  final Uint8List key;
  final Random rng;
  late final Uint8List u, ue, o, oe, perms;

  String dictionary() => '<</Filter/Standard/V 5/R 6/Length 256'
      '/CF<</StdCF<</AuthEvent/DocOpen/CFM/AESV3/Length 32>>>>/StmF/StdCF/StrF/StdCF'
      '/O<${_hex(o)}>/U<${_hex(u)}>/OE<${_hex(oe)}>/UE<${_hex(ue)}>/P $permissions/Perms<${_hex(perms)}>/EncryptMetadata true>>';

  /// AES-256-CBC with a random IV in front and PKCS#7 padding (AESV3).
  Uint8List encrypt(List<int> data) {
    final iv = _bytes(rng, 16);
    final pad = 16 - data.length % 16;
    final padded = Uint8List(data.length + pad)
      ..setAll(0, data)
      ..fillRange(data.length, data.length + pad, pad);
    final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(16 + padded.length)..setAll(0, iv);
    for (var i = 0; i < padded.length; i += 16) {
      cipher.processBlock(padded, i, out, 16 + i);
    }
    return out;
  }

  static Uint8List _aesCbcNoPad(List<int> key, List<int> data) {
    final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(Uint8List.fromList(key)), Uint8List(16)));
    final input = Uint8List.fromList(data);
    final out = Uint8List(input.length);
    for (var i = 0; i < input.length; i += 16) {
      cipher.processBlock(input, i, out, i);
    }
    return out;
  }

  /// Algorithm 2.B: the hash that makes guessing passwords slow.
  static Uint8List hardenedHash(List<int> password, List<int> salt, List<int> userKey) {
    var k = Uint8List.fromList(crypto.sha256.convert([...password, ...salt, ...userKey]).bytes);
    var round = 0;
    while (true) {
      final unit = [...password, ...k, ...userKey];
      final k1 = Uint8List(unit.length * 64);
      for (var i = 0; i < 64; i++) {
        k1.setAll(i * unit.length, unit);
      }
      final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(k.sublist(0, 16)), k.sublist(16, 32)));
      final e = Uint8List(k1.length);
      for (var i = 0; i < k1.length; i += 16) {
        cipher.processBlock(k1, i, e, i);
      }
      var sum = 0;
      for (var i = 0; i < 16; i++) {
        sum += e[i];
      }
      final digest = switch (sum % 3) { 0 => crypto.sha256, 1 => crypto.sha384, _ => crypto.sha512 };
      k = Uint8List.fromList(digest.convert(e).bytes);
      round++;
      if (round >= 64 && e.last <= round - 32) break;
    }
    return k.sublist(0, 32);
  }
}

// -----------------------------------------------------------------------------
// Reading the file

class _Ref {
  const _Ref(this.number, this.generation);

  final int number;
  final int generation;
}

/// A string's bytes.
class _Str {
  const _Str(this.bytes);

  final List<int> bytes;
}

class _Name {
  const _Name(this.value);

  final String value;
}

enum _T { name, number, keyword, string, dictOpen, dictClose, arrayOpen, arrayClose }

class _Token {
  _Token(this.type, this.raw, [this.bytes]);

  final _T type;

  /// The token as written (for strings, unused).
  final String raw;

  /// A string's decoded bytes.
  final List<int>? bytes;
}

bool _isSpace(int c) => c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
bool _isDelimiter(int c) => c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25;

class _Parser {
  _Parser(this.data);

  final Uint8List data;
  late final Map<int, (int, int)> _xref = _readXref();

  int _startxref() {
    final from = max(0, data.length - 1024);
    final tail = latin1.decode(data.sublist(from));
    final at = tail.lastIndexOf('startxref');
    if (at < 0) throw const FormatException('no startxref');
    final m = RegExp(r'\d+').firstMatch(tail.substring(at + 9));
    if (m == null) throw const FormatException('bad startxref');
    return int.parse(m.group(0)!);
  }

  /// Object number -> (offset, generation), from the one xref table.
  Map<int, (int, int)> _readXref() {
    var pos = _skipSpace(_startxref());
    if (!_startsWith(pos, 'xref')) throw const FormatException('the file uses a cross-reference stream');
    pos += 4;
    final result = <int, (int, int)>{};
    while (true) {
      pos = _skipSpace(pos);
      if (_startsWith(pos, 'trailer')) {
        _trailerAt = pos + 7;
        break;
      }
      final (start, p1) = _readInt(pos);
      final (count, p2) = _readInt(_skipSpace(p1));
      pos = p2;
      for (var i = 0; i < count; i++) {
        pos = _skipSpace(pos);
        if (pos + 18 > data.length) throw const FormatException('cut-off cross-reference table');
        final line = latin1.decode(data.sublist(pos, pos + 18));
        final offset = int.parse(line.substring(0, 10));
        final generation = int.parse(line.substring(11, 16));
        if (line[17] == 'n' && offset > 0) result[start + i] = (offset, generation);
        pos += 18;
      }
    }
    return result;
  }

  int _trailerAt = -1;

  Map<String, Object?> trailer() {
    _xref;
    final tokens = _tokens(_trailerAt, stopAtDictEnd: true).$1;
    final value = _value(tokens, 0).$1;
    if (value is! Map<String, Object?>) throw const FormatException('bad trailer');
    if (value.containsKey('Prev')) throw const FormatException('the file has several revisions');
    if (value.containsKey('XRefStm')) throw const FormatException('the file uses a cross-reference stream');
    return value;
  }

  /// Every object as its tokens plus, for streams, the raw stream data.
  Map<(int, int), _Object> objects() {
    final result = <(int, int), _Object>{};
    for (final MapEntry(key: number, value: (offset, generation)) in _xref.entries) {
      result[(number, generation)] = _object(number, offset);
    }
    return result;
  }

  _Object _object(int number, int offset) {
    var pos = _skipSpace(offset);
    final (n, p1) = _readInt(pos);
    final (_, p2) = _readInt(_skipSpace(p1));
    pos = _skipSpace(p2);
    if (n != number || !_startsWith(pos, 'obj')) throw FormatException('object $number is not where the table says');
    final (tokens, end) = _tokens(pos + 3);
    if (_startsWith(end, 'stream')) {
      var dataStart = end + 6;
      if (dataStart < data.length && data[dataStart] == 13) dataStart++;
      if (dataStart < data.length && data[dataStart] == 10) dataStart++;
      final dict = _value(tokens, 0).$1;
      if (dict is! Map<String, Object?>) throw FormatException('stream $number has no dictionary');
      final type = dict['Type'];
      // With a classic table nothing can point into these: they are left
      // over from the file's earlier form, and are dropped.
      if (type is _Name && (type.value == 'XRef' || type.value == 'ObjStm')) return _Object(tokens, null, leftover: true);
      final lengthValue = dict['Length'];
      final length = switch (lengthValue) {
        final int v => v,
        final _Ref r => _indirectInt(r.number),
        _ => throw FormatException('stream $number has no length'),
      };
      if (dataStart + length > data.length) throw FormatException('stream $number is cut off');
      return _Object(tokens, data.sublist(dataStart, dataStart + length));
    }
    return _Object(tokens, null);
  }

  int _indirectInt(int number) {
    final entry = _xref[number];
    if (entry == null) throw FormatException('missing object $number');
    final tokens = _object(number, entry.$1).tokens;
    final value = tokens.length == 1 ? int.tryParse(tokens.single.raw) : null;
    if (value == null) throw FormatException('object $number is not a number');
    return value;
  }

  /// Tokens from [pos] until `endobj` or `stream` at the top level (or the
  /// end of the first dictionary when [stopAtDictEnd]). Returns the tokens
  /// and where the stopping keyword starts.
  (List<_Token>, int) _tokens(int pos, {bool stopAtDictEnd = false}) {
    final tokens = <_Token>[];
    var depth = 0;
    while (true) {
      pos = _skipSpace(pos);
      if (pos >= data.length) throw const FormatException('unexpected end of file');
      final c = data[pos];
      if (c == 0x28) {
        final (bytes, end) = _literal(pos);
        tokens.add(_Token(_T.string, '', bytes));
        pos = end;
      } else if (c == 0x3C && pos + 1 < data.length && data[pos + 1] == 0x3C) {
        tokens.add(_Token(_T.dictOpen, '<<'));
        depth++;
        pos += 2;
      } else if (c == 0x3E && pos + 1 < data.length && data[pos + 1] == 0x3E) {
        tokens.add(_Token(_T.dictClose, '>>'));
        depth--;
        pos += 2;
        if (stopAtDictEnd && depth == 0) return (tokens, pos);
      } else if (c == 0x3C) {
        final end = data.indexOf(0x3E, pos);
        if (end < 0) throw const FormatException('unclosed hex string');
        final digits = latin1.decode(data.sublist(pos + 1, end)).replaceAll(RegExp(r'\s'), '');
        final even = digits.length.isOdd ? '${digits}0' : digits;
        final bytes = [for (var i = 0; i < even.length; i += 2) int.parse(even.substring(i, i + 2), radix: 16)];
        tokens.add(_Token(_T.string, '', bytes));
        pos = end + 1;
      } else if (c == 0x5B) {
        tokens.add(_Token(_T.arrayOpen, '['));
        depth++;
        pos++;
      } else if (c == 0x5D) {
        tokens.add(_Token(_T.arrayClose, ']'));
        depth--;
        pos++;
      } else if (c == 0x2F) {
        var end = pos + 1;
        while (end < data.length && !_isSpace(data[end]) && !_isDelimiter(data[end])) {
          end++;
        }
        tokens.add(_Token(_T.name, latin1.decode(data.sublist(pos, end))));
        pos = end;
      } else if (c == 0x25) {
        while (pos < data.length && data[pos] != 10 && data[pos] != 13) {
          pos++;
        }
      } else if (c == 0x7B || c == 0x7D || c == 0x29 || c == 0x3E) {
        throw FormatException('unexpected "${String.fromCharCode(c)}"');
      } else {
        var end = pos;
        while (end < data.length && !_isSpace(data[end]) && !_isDelimiter(data[end])) {
          end++;
        }
        final word = latin1.decode(data.sublist(pos, end));
        if (depth == 0 && (word == 'endobj' || word == 'stream')) return (tokens, pos);
        final isNumber = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$').hasMatch(word);
        tokens.add(_Token(isNumber ? _T.number : _T.keyword, word));
        pos = end;
      }
    }
  }

  (List<int>, int) _literal(int pos) {
    final out = <int>[];
    var depth = 1;
    pos++;
    while (pos < data.length) {
      final c = data[pos];
      if (c == 0x5C) {
        pos++;
        if (pos >= data.length) break;
        final e = data[pos];
        switch (e) {
          case 0x6E:
            out.add(10);
          case 0x72:
            out.add(13);
          case 0x74:
            out.add(9);
          case 0x62:
            out.add(8);
          case 0x66:
            out.add(12);
          case 13:
            // Line continuation: \ then CR or CRLF.
            if (pos + 1 < data.length && data[pos + 1] == 10) pos++;
          case 10:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var value = 0;
              var digits = 0;
              while (digits < 3 && pos < data.length && data[pos] >= 0x30 && data[pos] <= 0x37) {
                value = value * 8 + data[pos] - 0x30;
                pos++;
                digits++;
              }
              out.add(value & 0xFF);
              continue;
            }
            out.add(e);
        }
        pos++;
      } else if (c == 0x28) {
        depth++;
        out.add(c);
        pos++;
      } else if (c == 0x29) {
        depth--;
        pos++;
        if (depth == 0) return (out, pos);
        out.add(c);
      } else if (c == 13) {
        // An end of line inside a string reads as a single LF.
        out.add(10);
        pos++;
        if (pos < data.length && data[pos] == 10) pos++;
      } else {
        out.add(c);
        pos++;
      }
    }
    throw const FormatException('unclosed string');
  }

  /// Parses one value from [tokens] at [i] into Dart values (dictionaries as
  /// maps keyed without the slash). Returns it and the next index.
  (Object?, int) _value(List<_Token> tokens, int i) {
    if (i >= tokens.length) throw const FormatException('missing value');
    final t = tokens[i];
    switch (t.type) {
      case _T.dictOpen:
        final map = <String, Object?>{};
        i++;
        while (i < tokens.length && tokens[i].type != _T.dictClose) {
          final key = tokens[i];
          if (key.type != _T.name) throw const FormatException('bad dictionary key');
          final (value, next) = _value(tokens, i + 1);
          map[key.raw.substring(1)] = value;
          i = next;
        }
        return (map, i + 1);
      case _T.arrayOpen:
        final list = <Object?>[];
        i++;
        while (i < tokens.length && tokens[i].type != _T.arrayClose) {
          final (value, next) = _value(tokens, i);
          list.add(value);
          i = next;
        }
        return (list, i + 1);
      case _T.number:
        // "n g R" is a reference.
        if (i + 2 < tokens.length && tokens[i + 1].type == _T.number && tokens[i + 2].raw == 'R') {
          return (_Ref(int.parse(t.raw), int.parse(tokens[i + 1].raw)), i + 3);
        }
        return (int.tryParse(t.raw) ?? double.tryParse(t.raw), i + 1);
      case _T.string:
        return (_Str(t.bytes!), i + 1);
      case _T.name:
        return (_Name(t.raw.substring(1)), i + 1);
      case _T.keyword:
        return (t.raw, i + 1);
      case _T.dictClose || _T.arrayClose:
        throw const FormatException('unbalanced brackets');
    }
  }

  /// The object's body with every string and its stream encrypted.
  Uint8List encryptObject(_Object object, _SecurityHandler security, {required bool isCatalog}) {
    final out = BytesBuilder(copy: false);
    final stream = object.stream == null ? null : security.encrypt(object.stream!);
    var depth = 0;
    final tokens = object.tokens;
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      // Replace the stream's length with the encrypted length.
      if (stream != null && depth == 1 && t.type == _T.name && t.raw == '/Length') {
        out.add(latin1.encode('/Length ${stream.length} '));
        final (_, next) = _value(tokens, i + 1);
        i = next - 1;
        continue;
      }
      switch (t.type) {
        case _T.string:
          out.add(latin1.encode('<${_hex(security.encrypt(t.bytes!))}>'));
        case _T.dictOpen:
          depth++;
          out.add(latin1.encode('<<'));
          // Mark the catalog as using Adobe's AES-256 extension.
          if (isCatalog && depth == 1 && !tokens.any((x) => x.type == _T.name && x.raw == '/Extensions')) {
            out.add(latin1.encode('/Extensions<</ADBE<</BaseVersion/1.7/ExtensionLevel 8>>>>'));
          }
        case _T.dictClose:
          depth--;
          out.add(latin1.encode('>>'));
        case _T.arrayOpen:
          depth++;
          out.add(latin1.encode('['));
        case _T.arrayClose:
          depth--;
          out.add(latin1.encode(']'));
        case _T.name || _T.number || _T.keyword:
          out.add(latin1.encode(t.raw));
          out.addByte(32);
      }
    }
    if (stream != null) {
      out.add(latin1.encode('\nstream\r\n'));
      out.add(stream);
      out.add(latin1.encode('\r\nendstream'));
    }
    return out.toBytes();
  }

  bool _startsWith(int pos, String word) {
    if (pos + word.length > data.length) return false;
    for (var i = 0; i < word.length; i++) {
      if (data[pos + i] != word.codeUnitAt(i)) return false;
    }
    return true;
  }

  int _skipSpace(int pos) {
    while (pos < data.length) {
      final c = data[pos];
      if (_isSpace(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < data.length && data[pos] != 10 && data[pos] != 13) {
          pos++;
        }
      } else {
        break;
      }
    }
    return pos;
  }

  (int, int) _readInt(int pos) {
    var end = pos;
    while (end < data.length && data[end] >= 0x30 && data[end] <= 0x39) {
      end++;
    }
    if (end == pos) throw FormatException('expected a number at $pos');
    return (int.parse(latin1.decode(data.sublist(pos, end))), end);
  }
}

class _Object {
  _Object(this.tokens, this.stream, {this.leftover = false});

  final List<_Token> tokens;
  final Uint8List? stream;

  /// An old cross-reference or object stream that nothing uses.
  final bool leftover;
}
