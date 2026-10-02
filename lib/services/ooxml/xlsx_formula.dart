import 'dart:math' as math;

import 'xlsx_reader.dart';

/// An Excel error value such as `#DIV/0!`.
class FormulaError {
  const FormulaError(this.code);

  final String code;

  static const div0 = FormulaError('#DIV/0!');
  static const value = FormulaError('#VALUE!');
  static const ref = FormulaError('#REF!');
  static const na = FormulaError('#N/A');
  static const num = FormulaError('#NUM!');

  @override
  bool operator ==(Object other) => other is FormulaError && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

/// Thrown for formulas the app cannot work out (unknown functions, names,
/// whole-column references). Callers keep the value Excel last saved.
class UnsupportedFormula implements Exception {
  const UnsupportedFormula(this.reason);

  final String reason;

  @override
  String toString() => 'Unsupported formula: $reason';
}

/// Value of a cell for formulas: a double, String, bool, [FormulaError], or
/// null for an empty cell. [sheet] is null for the formula's own sheet.
typedef CellLookup = Object? Function(String? sheet, int row, int col);

class _Range {
  _Range(this.rows, this.cols, this.values);

  final int rows;
  final int cols;

  /// Row-major values.
  final List<Object?> values;

  Object? at(int r, int c) => values[r * cols + c];
}

class _Raise implements Exception {
  const _Raise(this.error);

  final FormulaError error;
}

/// A cell reference found in formula text.
class FormulaRef {
  const FormulaRef({this.sheet, required this.row, required this.col, this.rowAbs = false, this.colAbs = false});

  /// Sheet name without quotes, or null for the formula's own sheet.
  final String? sheet;
  final int row;
  final int col;
  final bool rowAbs;
  final bool colAbs;

  String get a1 => '${colAbs ? r'$' : ''}${XlsxReader.columnName(col)}${rowAbs ? r'$' : ''}${row + 1}';
}

/// Quotes a sheet name for use in a formula when it needs it.
String quoteSheetName(String name) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_.]*$').hasMatch(name) && !RegExp(r'^[A-Za-z]{1,3}\d+$').hasMatch(name) ? name : "'${name.replaceAll("'", "''")}'";

/// Matches A1 references and ranges, with an optional sheet prefix, outside
/// of function names and defined names.
final _refPattern = RegExp(
  r"(?<![\w.$À-￿])((?:'(?:[^']|'')+'|[A-Za-z_À-￿][\w.À-￿]*)!)?(\$?)([A-Za-z]{1,3})(\$?)(\d+)(?::(\$?)([A-Za-z]{1,3})(\$?)(\d+))?(?![\w(À-￿])",
);

/// Rewrites every A1 reference in [formula] (not inside string literals).
/// [map] gets each reference, or each end of a range, and returns its new
/// text, or null for `#REF!`. [mapRange] can rewrite a whole range instead.
String mapFormulaRefs(
  String formula,
  String? Function(FormulaRef ref) map, {
  String? Function(FormulaRef from, FormulaRef to)? mapRange,
}) {
  final out = StringBuffer();
  var i = 0;
  // Walk string literals separately so text like "A1" is left alone.
  final literal = RegExp(r'"(?:[^"]|"")*"');
  for (final m in literal.allMatches(formula)) {
    out.write(_mapSegment(formula.substring(i, m.start), map, mapRange));
    out.write(m.group(0));
    i = m.end;
  }
  out.write(_mapSegment(formula.substring(i), map, mapRange));
  return out.toString();
}

String _mapSegment(String text, String? Function(FormulaRef) map, String? Function(FormulaRef, FormulaRef)? mapRange) {
  return text.replaceAllMapped(_refPattern, (m) {
    final prefix = m.group(1);
    String? sheet;
    if (prefix != null) {
      final raw = prefix.substring(0, prefix.length - 1);
      sheet = raw.startsWith("'") ? raw.substring(1, raw.length - 1).replaceAll("''", "'") : raw;
    }
    final colIndex = XlsxReader.columnIndex(m.group(3)!);
    if (colIndex > 16383) return m.group(0)!; // not a cell (e.g. a name like ABCD1)
    final first = FormulaRef(sheet: sheet, row: int.parse(m.group(5)!) - 1, col: colIndex, colAbs: m.group(2) == r'$', rowAbs: m.group(4) == r'$');
    if (m.group(7) == null) {
      final a = map(first);
      return a == null ? '#REF!' : '${prefix ?? ''}$a';
    }
    final second = FormulaRef(sheet: sheet, row: int.parse(m.group(9)!) - 1, col: XlsxReader.columnIndex(m.group(7)!), colAbs: m.group(6) == r'$', rowAbs: m.group(8) == r'$');
    if (mapRange != null) {
      final r = mapRange(first, second);
      return r == null ? '#REF!' : '${prefix ?? ''}$r';
    }
    final a = map(first);
    final b = map(second);
    return a == null || b == null ? '#REF!' : '${prefix ?? ''}$a:$b';
  });
}

/// Evaluates Excel formulas for the most common functions, so edited
/// sheets show up-to-date results. Excel recalculates everything again when
/// the file is opened.
class FormulaEngine {
  FormulaEngine._(this._src, this._lookup);

  final String _src;
  final CellLookup _lookup;
  int _pos = 0;

  /// Evaluates [formula] (without the leading `=`). Returns a double, String,
  /// bool or [FormulaError]. Throws [UnsupportedFormula] when it can't.
  static Object evaluate(String formula, CellLookup lookup) {
    final engine = FormulaEngine._(formula, lookup);
    try {
      final v = engine._comparison();
      engine._skip();
      if (engine._pos < formula.length) throw UnsupportedFormula('unexpected "${formula.substring(engine._pos)}"');
      final result = engine._scalar(v);
      return result ?? 0.0;
    } on _Raise catch (e) {
      return e.error;
    }
  }

  // ---- Parsing and evaluation (one pass, recursive descent) ----

  void _skip() {
    while (_pos < _src.length && (_src[_pos] == ' ' || _src[_pos] == '\n' || _src[_pos] == '\r')) {
      _pos++;
    }
  }

  bool _eat(String token) {
    _skip();
    if (_src.startsWith(token, _pos)) {
      _pos += token.length;
      return true;
    }
    return false;
  }

  Object? _comparison() {
    var left = _concat();
    while (true) {
      String? op;
      for (final o in const ['<>', '<=', '>=', '=', '<', '>']) {
        if (_eat(o)) {
          op = o;
          break;
        }
      }
      if (op == null) return left;
      final right = _concat();
      left = _compare(_scalar(left), _scalar(right), op);
    }
  }

  Object? _concat() {
    var left = _additive();
    while (_eat('&')) {
      final right = _additive();
      left = _text(_scalar(left)) + _text(_scalar(right));
    }
    return left;
  }

  Object? _additive() {
    var left = _multiplicative();
    while (true) {
      if (_eat('+')) {
        left = _num(_scalar(left)) + _num(_scalar(_multiplicative()));
      } else if (_eat('-')) {
        left = _num(_scalar(left)) - _num(_scalar(_multiplicative()));
      } else {
        return left;
      }
    }
  }

  Object? _multiplicative() {
    var left = _power();
    while (true) {
      if (_eat('*')) {
        left = _num(_scalar(left)) * _num(_scalar(_power()));
      } else if (_eat('/')) {
        final d = _num(_scalar(_power()));
        if (d == 0) throw const _Raise(FormulaError.div0);
        left = _num(_scalar(left)) / d;
      } else {
        return left;
      }
    }
  }

  Object? _power() {
    var left = _percent();
    while (_eat('^')) {
      left = math.pow(_num(_scalar(left)), _num(_scalar(_percent()))).toDouble();
    }
    return left;
  }

  Object? _percent() {
    var v = _unary();
    while (_eat('%')) {
      v = _num(_scalar(v)) / 100;
    }
    return v;
  }

  Object? _unary() {
    if (_eat('-')) return -_num(_scalar(_unary()));
    if (_eat('+')) return _unary();
    return _primary();
  }

  Object? _primary() {
    _skip();
    if (_pos >= _src.length) throw const UnsupportedFormula('unexpected end');
    final ch = _src[_pos];
    if (ch == '(') {
      _pos++;
      final v = _comparison();
      if (!_eat(')')) throw const UnsupportedFormula('missing )');
      return v;
    }
    if (ch == '"') {
      final m = RegExp(r'"((?:[^"]|"")*)"').matchAsPrefix(_src, _pos);
      if (m == null) throw const UnsupportedFormula('bad string');
      _pos = m.end;
      return m.group(1)!.replaceAll('""', '"');
    }
    if (ch == '#') {
      final m = RegExp(r'#(DIV/0!|VALUE!|REF!|NAME\?|N/A|NUM!|NULL!)').matchAsPrefix(_src, _pos);
      if (m == null) throw const UnsupportedFormula('bad error literal');
      _pos = m.end;
      throw _Raise(FormulaError(m.group(0)!));
    }
    final number = RegExp(r'(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').matchAsPrefix(_src, _pos);
    if (number != null) {
      _pos = number.end;
      return double.parse(number.group(0)!);
    }
    final ref = _refPattern.matchAsPrefix(_src, _pos);
    if (ref != null) {
      _pos = ref.end;
      return _resolveRef(ref);
    }
    final ident = RegExp(r'[A-Za-z_][A-Za-z0-9_.]*').matchAsPrefix(_src, _pos);
    if (ident != null) {
      final name = ident.group(0)!.toUpperCase();
      _pos = ident.end;
      if (_eat('(')) return _call(name.replaceFirst('_XLFN.', ''));
      if (name == 'TRUE') return true;
      if (name == 'FALSE') return false;
      throw UnsupportedFormula('name $name');
    }
    throw UnsupportedFormula('unexpected "$ch"');
  }

  Object? _resolveRef(Match m) {
    final prefix = m.group(1);
    String? sheet;
    if (prefix != null) {
      final raw = prefix.substring(0, prefix.length - 1);
      sheet = raw.startsWith("'") ? raw.substring(1, raw.length - 1).replaceAll("''", "'") : raw;
    }
    final r1 = int.parse(m.group(5)!) - 1;
    final c1 = XlsxReader.columnIndex(m.group(3)!);
    if (m.group(7) == null) return _cell(sheet, r1, c1);
    final r2 = int.parse(m.group(9)!) - 1;
    final c2 = XlsxReader.columnIndex(m.group(7)!);
    final top = math.min(r1, r2), bottom = math.max(r1, r2);
    final left = math.min(c1, c2), right = math.max(c1, c2);
    final rows = bottom - top + 1, cols = right - left + 1;
    if (rows * cols > 200000) throw const UnsupportedFormula('range too large');
    return _Range(rows, cols, [
      for (var r = top; r <= bottom; r++)
        for (var c = left; c <= right; c++) _cell(sheet, r, c),
    ]);
  }

  Object? _cell(String? sheet, int r, int c) {
    final v = _lookup(sheet, r, c);
    return v;
  }

  List<Object?> _args() {
    final args = <Object?>[];
    if (_eat(')')) return args;
    do {
      _skip();
      // Empty argument, as in IF(A1,,1).
      if (_pos < _src.length && (_src[_pos] == ',' || _src[_pos] == ')')) {
        args.add(null);
        continue;
      }
      try {
        args.add(_comparison());
      } on _Raise catch (e) {
        // Keep the error as a value so IFERROR and friends can see it.
        args.add(e.error);
        _skipArgument();
      }
    } while (_eat(','));
    if (!_eat(')')) throw const UnsupportedFormula('missing )');
    return args;
  }

  /// After an error inside an argument, skips to the next , or ) at this level.
  void _skipArgument() {
    var depth = 0;
    var quoted = false;
    while (_pos < _src.length) {
      final ch = _src[_pos];
      if (ch == '"') quoted = !quoted;
      if (!quoted) {
        if (ch == '(') depth++;
        if (ch == ')') {
          if (depth == 0) return;
          depth--;
        }
        if (ch == ',' && depth == 0) return;
      }
      _pos++;
    }
  }

  // ---- Values ----

  Object? _scalar(Object? v) {
    if (v is _Range) {
      if (v.values.length == 1) return _scalar(v.values.first);
      throw const _Raise(FormulaError.value);
    }
    if (v is FormulaError) throw _Raise(v);
    return v;
  }

  double _num(Object? v) {
    if (v == null) return 0;
    if (v is double) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is String) {
      final d = double.tryParse(v.trim().replaceAll(',', ''));
      if (d == null) throw const _Raise(FormulaError.value);
      return d;
    }
    if (v is FormulaError) throw _Raise(v);
    throw const _Raise(FormulaError.value);
  }

  static String _text(Object? v) {
    if (v == null) return '';
    if (v is double) return XlsxReader.formatNumber(v.toString());
    if (v is bool) return v ? 'TRUE' : 'FALSE';
    if (v is FormulaError) throw _Raise(v);
    return v.toString();
  }

  bool _bool(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is double) return v != 0;
    if (v is String) {
      if (v.toUpperCase() == 'TRUE') return true;
      if (v.toUpperCase() == 'FALSE') return false;
      throw const _Raise(FormulaError.value);
    }
    if (v is FormulaError) throw _Raise(v);
    return false;
  }

  static int _typeRank(Object? v) => v is double ? 0 : (v is String ? 1 : (v is bool ? 2 : -1));

  bool _compare(Object? a, Object? b, String op) {
    // Empty cells compare as 0 or "" depending on the other side.
    a ??= b is String ? '' : (b is bool ? false : 0.0);
    b ??= a is String ? '' : (a is bool ? false : 0.0);
    int cmp;
    if (_typeRank(a) != _typeRank(b)) {
      cmp = _typeRank(a).compareTo(_typeRank(b));
    } else if (a is String && b is String) {
      cmp = a.toLowerCase().compareTo(b.toLowerCase());
    } else if (a is bool && b is bool) {
      cmp = (a ? 1 : 0).compareTo(b ? 1 : 0);
    } else {
      cmp = (a as double).compareTo(b as double);
    }
    return switch (op) {
      '=' => cmp == 0,
      '<>' => cmp != 0,
      '<' => cmp < 0,
      '>' => cmp > 0,
      '<=' => cmp <= 0,
      _ => cmp >= 0,
    };
  }

  /// Numbers for aggregate functions: ranges contribute only their numbers,
  /// direct arguments are converted.
  Iterable<double> _numbers(List<Object?> args) sync* {
    for (final a in args) {
      if (a is _Range) {
        for (final v in a.values) {
          if (v is FormulaError) throw _Raise(v);
          if (v is double) yield v;
        }
      } else if (a != null) {
        yield _num(a);
      }
    }
  }

  Iterable<Object?> _flat(List<Object?> args) sync* {
    for (final a in args) {
      if (a is _Range) {
        yield* a.values;
      } else {
        yield a;
      }
    }
  }

  bool Function(Object?) _criteria(Object? c) {
    c = _scalar(c);
    if (c is String) {
      final m = RegExp(r'^(<>|<=|>=|=|<|>)?(.*)$').firstMatch(c)!;
      final op = m.group(1) ?? '=';
      final rest = m.group(2)!;
      final n = double.tryParse(rest);
      if (n != null) return (v) => v is double && _compare(v, n, op);
      if (op == '=' && (rest.contains('*') || rest.contains('?'))) {
        final pattern = RegExp('^${RegExp.escape(rest).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$', caseSensitive: false);
        return (v) => v is String && pattern.hasMatch(v);
      }
      return (v) => _compare(v ?? '', rest, op);
    }
    return (v) => v != null && _typeRank(v) == _typeRank(c) && _compare(v, c, '=');
  }

  double _round(double v, double digits, int mode) {
    final f = math.pow(10, digits.truncate()).toDouble();
    // Excel works to 15 significant digits, so 2.345 * 100 is 234.5, not 234.4999….
    final x = double.parse((v * f).toStringAsPrecision(15));
    final r = switch (mode) {
      0 => (x.abs() + 0.5).floorToDouble() * x.sign,
      1 => x.abs().ceilToDouble() * x.sign,
      _ => x.abs().floorToDouble() * x.sign,
    };
    return r / f;
  }

  Object? _call(String name) {
    // IF and IFERROR only evaluate the branch they need, as Excel does.
    final args = _args();
    Object? arg(int i) => i < args.length ? args[i] : null;
    void need(int min, [int? max]) {
      if (args.length < min || (max != null && args.length > max)) throw UnsupportedFormula('$name arguments');
    }

    switch (name) {
      case 'SUM':
        return _numbers(args).fold<double>(0, (a, b) => a + b);
      case 'PRODUCT':
        return _numbers(args).fold<double>(1, (a, b) => a * b);
      case 'AVERAGE':
        final n = _numbers(args).toList();
        if (n.isEmpty) throw const _Raise(FormulaError.div0);
        return n.reduce((a, b) => a + b) / n.length;
      case 'MIN':
        final n = _numbers(args).toList();
        return n.isEmpty ? 0.0 : n.reduce(math.min);
      case 'MAX':
        final n = _numbers(args).toList();
        return n.isEmpty ? 0.0 : n.reduce(math.max);
      case 'COUNT':
        return _flat(args).whereType<double>().length.toDouble();
      case 'COUNTA':
        return _flat(args).where((v) => v != null && v != '').length.toDouble();
      case 'COUNTBLANK':
        return _flat(args).where((v) => v == null || v == '').length.toDouble();
      case 'IF':
        need(2, 3);
        return _bool(_scalar(arg(0))) ? arg(1) : (args.length > 2 ? arg(2) : false);
      case 'IFERROR':
        need(2, 2);
        final v = arg(0);
        if (v is FormulaError) return arg(1);
        if (v is _Range && v.values.length == 1 && v.values.first is FormulaError) return arg(1);
        return v;
      case 'ISBLANK':
        need(1, 1);
        return _scalarOrNull(arg(0)) == null;
      case 'ISNUMBER':
        need(1, 1);
        return _scalarOrNull(arg(0)) is double;
      case 'ISTEXT':
        need(1, 1);
        return _scalarOrNull(arg(0)) is String;
      case 'ISERROR':
        need(1, 1);
        return _scalarOrNull(arg(0)) is FormulaError;
      case 'AND':
        return _flat(args).where((v) => v != null).every(_bool);
      case 'OR':
        return _flat(args).where((v) => v != null).any(_bool);
      case 'NOT':
        need(1, 1);
        return !_bool(_scalar(arg(0)));
      case 'ROUND' || 'ROUNDUP' || 'ROUNDDOWN':
        need(1, 2);
        return _round(_num(_scalar(arg(0))), _num(_scalar(arg(1))), name == 'ROUND' ? 0 : (name == 'ROUNDUP' ? 1 : 2));
      case 'INT':
        need(1, 1);
        return _num(_scalar(arg(0))).floorToDouble();
      case 'ABS':
        need(1, 1);
        return _num(_scalar(arg(0))).abs();
      case 'MOD':
        need(2, 2);
        final d = _num(_scalar(arg(1)));
        if (d == 0) throw const _Raise(FormulaError.div0);
        final n = _num(_scalar(arg(0)));
        return n - d * (n / d).floorToDouble();
      case 'SQRT':
        need(1, 1);
        final n = _num(_scalar(arg(0)));
        if (n < 0) throw const _Raise(FormulaError.num);
        return math.sqrt(n);
      case 'POWER':
        need(2, 2);
        return math.pow(_num(_scalar(arg(0))), _num(_scalar(arg(1)))).toDouble();
      case 'PI':
        return math.pi;
      case 'LEN':
        need(1, 1);
        return _text(_scalar(arg(0))).length.toDouble();
      case 'UPPER':
        need(1, 1);
        return _text(_scalar(arg(0))).toUpperCase();
      case 'LOWER':
        need(1, 1);
        return _text(_scalar(arg(0))).toLowerCase();
      case 'TRIM':
        need(1, 1);
        return _text(_scalar(arg(0))).trim().replaceAll(RegExp(r' +'), ' ');
      case 'CONCATENATE' || 'CONCAT':
        return _flat(args).map((v) => _text(v)).join();
      case 'LEFT' || 'RIGHT':
        need(1, 2);
        final s = _text(_scalar(arg(0)));
        final n = args.length > 1 ? _num(_scalar(arg(1))).toInt() : 1;
        if (n < 0) throw const _Raise(FormulaError.value);
        return name == 'LEFT' ? s.substring(0, math.min(n, s.length)) : s.substring(math.max(0, s.length - n));
      case 'MID':
        need(3, 3);
        final s = _text(_scalar(arg(0)));
        final start = _num(_scalar(arg(1))).toInt() - 1;
        final n = _num(_scalar(arg(2))).toInt();
        if (start < 0 || n < 0) throw const _Raise(FormulaError.value);
        if (start >= s.length) return '';
        return s.substring(start, math.min(s.length, start + n));
      case 'SUMIF' || 'COUNTIF' || 'AVERAGEIF':
        need(2, name == 'COUNTIF' ? 2 : 3);
        final range = arg(0);
        if (range is! _Range) throw const _Raise(FormulaError.value);
        final test = _criteria(arg(1));
        final sumRange = args.length > 2 && arg(2) is _Range ? arg(2) as _Range : range;
        var count = 0;
        var sum = 0.0;
        for (var i = 0; i < range.values.length; i++) {
          if (!test(range.values[i])) continue;
          count++;
          final v = i < sumRange.values.length ? sumRange.values[i] : null;
          if (v is double) sum += v;
        }
        if (name == 'COUNTIF') return count.toDouble();
        if (name == 'SUMIF') return sum;
        if (count == 0) throw const _Raise(FormulaError.div0);
        return sum / count;
      case 'VLOOKUP':
        need(3, 4);
        final key = _scalar(arg(0));
        final table = arg(1);
        if (table is! _Range) throw const _Raise(FormulaError.value);
        final col = _num(_scalar(arg(2))).toInt() - 1;
        if (col < 0 || col >= table.cols) throw const _Raise(FormulaError.ref);
        final approximate = args.length < 4 || _bool(_scalar(arg(3)));
        var match = -1;
        for (var r = 0; r < table.rows; r++) {
          final v = table.at(r, 0);
          if (approximate) {
            if (v != null && _typeRank(v) == _typeRank(key) && _compare(v, key, '<=')) {
              match = r;
            } else if (v != null && _typeRank(v) == _typeRank(key)) {
              break;
            }
          } else if (v != null && _compare(v, key, '=') && _typeRank(v) == _typeRank(key)) {
            match = r;
            break;
          }
        }
        if (match < 0) throw const _Raise(FormulaError.na);
        return table.at(match, col);
      case 'MATCH':
        need(2, 3);
        final key = _scalar(arg(0));
        final list = arg(1);
        if (list is! _Range) throw const _Raise(FormulaError.na);
        final type = args.length > 2 ? _num(_scalar(arg(2))).toInt() : 1;
        if (type != 0) throw const UnsupportedFormula('approximate MATCH');
        for (var i = 0; i < list.values.length; i++) {
          final v = list.values[i];
          if (v != null && _typeRank(v) == _typeRank(key) && _compare(v, key, '=')) return (i + 1).toDouble();
        }
        throw const _Raise(FormulaError.na);
      case 'INDEX':
        need(2, 3);
        final table = arg(0);
        if (table is! _Range) return arg(0);
        var r = _num(_scalar(arg(1))).toInt();
        var c = args.length > 2 ? _num(_scalar(arg(2))).toInt() : 1;
        if (table.rows == 1 && args.length == 2) {
          c = r;
          r = 1;
        }
        if (r < 1 || c < 1 || r > table.rows || c > table.cols) throw const _Raise(FormulaError.ref);
        return table.at(r - 1, c - 1);
      default:
        throw UnsupportedFormula('function $name');
    }
  }

  Object? _scalarOrNull(Object? v) {
    if (v is _Range) return v.values.length == 1 ? v.values.first : FormulaError.value;
    return v;
  }
}
