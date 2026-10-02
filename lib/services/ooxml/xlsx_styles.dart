import 'package:xml/xml.dart';

import 'xml_utils.dart';

/// The parts of an Excel cell format that the app shows: font weight,
/// slant and colour, background fill, alignment and number format.
class XlsxCellStyle {
  const XlsxCellStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontColor,
    this.fill,
    this.align,
    this.numFmtId = 0,
    this.numFmt,
  });

  final bool bold;
  final bool italic;
  final bool underline;

  /// RGB hex like `C00000`, or null for automatic.
  final String? fontColor;
  final String? fill;

  /// `left`, `center` or `right`, or null for Excel's default.
  final String? align;
  final int numFmtId;

  /// Custom format code, when [numFmtId] is not a built-in format.
  final String? numFmt;

  static const plain = XlsxCellStyle();

  String? get formatCode => numFmt ?? _builtInFormats[numFmtId];

  bool get isDate => isDateFormat(formatCode);

  static const _builtInFormats = {
    1: '0',
    2: '0.00',
    3: '#,##0',
    4: '#,##0.00',
    9: '0%',
    10: '0.00%',
    11: '0.00E+00',
    14: 'd/m/yyyy',
    15: 'd-mmm-yy',
    16: 'd-mmm',
    17: 'mmm-yy',
    18: 'h:mm AM/PM',
    19: 'h:mm:ss AM/PM',
    20: 'h:mm',
    21: 'h:mm:ss',
    22: 'd/m/yyyy h:mm',
    37: '#,##0 ;(#,##0)',
    38: '#,##0 ;[Red](#,##0)',
    39: '#,##0.00;(#,##0.00)',
    40: '#,##0.00;[Red](#,##0.00)',
    45: 'mm:ss',
    46: '[h]:mm:ss',
    47: 'mmss.0',
    49: '@',
  };

  static bool isDateFormat(String? code) {
    if (code == null) return false;
    // Ignore quoted text, escapes and colour/condition brackets before looking for date tokens.
    final bare = code.replaceAll(RegExp(r'"[^"]*"|\\.|\[[^\]]*\]'), '');
    return RegExp(r'[dmyhs]', caseSensitive: false).hasMatch(bare) && !bare.contains('E+');
  }
}

/// Reads `xl/styles.xml` into one [XlsxCellStyle] per `cellXfs` entry.
class XlsxStyles {
  XlsxStyles(this.styles);

  factory XlsxStyles.parse(XmlDocument? xml) {
    if (xml == null) return XlsxStyles(const []);
    final root = xml.rootElement;
    final numFmts = <int, String>{
      for (final f in root.kid('numFmts')?.kids('numFmt') ?? const <XmlElement>[])
        if (int.tryParse(f.attr('numFmtId') ?? '') != null) int.parse(f.attr('numFmtId')!): f.attr('formatCode') ?? '',
    };
    final fonts = root.kid('fonts')?.kids('font').toList() ?? const <XmlElement>[];
    final fills = root.kid('fills')?.kids('fill').toList() ?? const <XmlElement>[];
    final styles = <XlsxCellStyle>[];
    for (final xf in root.kid('cellXfs')?.kids('xf') ?? const <XmlElement>[]) {
      final fontId = int.tryParse(xf.attr('fontId') ?? '') ?? 0;
      final fillId = int.tryParse(xf.attr('fillId') ?? '') ?? 0;
      final numFmtId = int.tryParse(xf.attr('numFmtId') ?? '') ?? 0;
      final font = fontId < fonts.length ? fonts[fontId] : null;
      final fill = fillId < fills.length ? fills[fillId] : null;
      final pattern = fill?.kid('patternFill');
      final solid = pattern?.attr('patternType') == 'solid';
      styles.add(XlsxCellStyle(
        bold: font?.kid('b')?.isOn ?? false,
        italic: font?.kid('i')?.isOn ?? false,
        underline: font?.kid('u') != null && font?.kid('u')?.attr('val') != 'none',
        fontColor: rgb(font?.kid('color')),
        fill: solid ? rgb(pattern?.kid('fgColor')) : null,
        align: xf.kid('alignment')?.attr('horizontal'),
        numFmtId: numFmtId,
        numFmt: numFmts[numFmtId],
      ));
    }
    return XlsxStyles(styles);
  }

  final List<XlsxCellStyle> styles;

  XlsxCellStyle operator [](int index) => index >= 0 && index < styles.length ? styles[index] : XlsxCellStyle.plain;

  /// Excel's legacy 64-colour palette, for `indexed` colours.
  static const _indexed = [
    '000000', 'FFFFFF', 'FF0000', '00FF00', '0000FF', 'FFFF00', 'FF00FF', '00FFFF', //
    '000000', 'FFFFFF', 'FF0000', '00FF00', '0000FF', 'FFFF00', 'FF00FF', '00FFFF',
    '800000', '008000', '000080', '808000', '800080', '008080', 'C0C0C0', '808080',
    '9999FF', '993366', 'FFFFCC', 'CCFFFF', '660066', 'FF8080', '0066CC', 'CCCCFF',
    '000080', 'FF00FF', 'FFFF00', '00FFFF', '800080', '800000', '008080', '0000FF',
    '00CCFF', 'CCFFFF', 'CCFFCC', 'FFFF99', '99CCFF', 'FF99CC', 'CC99FF', 'FFCC99',
    '3366FF', '33CCCC', '99CC00', 'FFCC00', 'FF9900', 'FF6600', '666699', '969696',
    '003366', '339966', '003300', '333300', '993300', '993366', '333399', '333333',
  ];

  /// Default Office theme colours by `theme` index (lt1, dk1, lt2, dk2, accents).
  static const _theme = ['FFFFFF', '000000', 'E7E6E6', '44546A', '4472C4', 'ED7D31', 'A5A5A5', 'FFC000', '5B9BD5', '70AD47'];

  /// RGB hex of a SpreadsheetML colour element, or null for automatic.
  static String? rgb(XmlElement? color) {
    if (color == null || color.attr('auto') == '1') return null;
    String? hex;
    final argb = color.attr('rgb');
    if (argb != null && argb.length >= 6) hex = argb.substring(argb.length - 6).toUpperCase();
    final indexed = int.tryParse(color.attr('indexed') ?? '');
    if (hex == null && indexed != null && indexed < _indexed.length) hex = _indexed[indexed];
    final theme = int.tryParse(color.attr('theme') ?? '');
    if (hex == null && theme != null && theme < _theme.length) hex = _theme[theme];
    if (hex == null) return null;
    final tint = double.tryParse(color.attr('tint') ?? '');
    if (tint == null || tint == 0) return hex;
    String ch(int i) {
      final v = int.parse(hex!.substring(i, i + 2), radix: 16) / 255;
      final t = tint < 0 ? v * (1 + tint) : v + (1 - v) * tint;
      return (t * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    }

    return '${ch(0)}${ch(2)}${ch(4)}'.toUpperCase();
  }
}

/// Formats a stored number the way Excel displays it for common formats:
/// thousands separators, fixed decimals, percentages and dates.
String formatExcelNumber(double value, XlsxCellStyle style, {bool date1904 = false}) {
  final code = style.formatCode;
  if (code == null || code == 'General' || code == '@') return _general(value);
  final sections = _splitSections(code);
  var section = sections.first;
  var v = value;
  if (value < 0 && sections.length > 1) {
    section = sections[1];
    v = -value;
  } else if (value == 0 && sections.length > 2) {
    section = sections[2];
  }
  final clean = section.replaceAll(RegExp(r'\[[^\]]*\]'), '');
  if (XlsxCellStyle.isDateFormat(clean)) return _date(value, clean, date1904);
  final percent = clean.contains('%');
  if (percent) v *= 100;
  final numberPart = RegExp(r'[#0?,.]+').firstMatch(clean.replaceAll(RegExp(r'"[^"]*"'), ''))?.group(0);
  if (numberPart == null) return _general(value);
  final dot = numberPart.indexOf('.');
  final decimals = dot < 0 ? 0 : numberPart.substring(dot + 1).replaceAll(RegExp(r'[^0#?]'), '').length;
  final grouping = numberPart.contains(',') && (dot < 0 || numberPart.indexOf(',') < dot);
  var text = v.abs().toStringAsFixed(decimals);
  if (grouping) {
    final parts = text.split('.');
    parts[0] = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    text = parts.join('.');
  }
  final literalBefore = clean.substring(0, clean.indexOf(numberPart[0])).replaceAll(RegExp(r'["\\_*]'), '').replaceAll(RegExp(r'\s+$'), '');
  final afterIndex = clean.lastIndexOf(numberPart[numberPart.length - 1]) + 1;
  final literalAfter = clean.substring(afterIndex.clamp(0, clean.length)).replaceAll(RegExp(r'["\\]'), '').replaceAll(RegExp(r'_.|\*.'), '');
  final sign = v < 0 && sections.length == 1 ? '-' : '';
  return '$sign$literalBefore$text$literalAfter'.trim();
}

List<String> _splitSections(String code) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  for (final ch in code.split('')) {
    if (ch == '"') quoted = !quoted;
    if (ch == ';' && !quoted) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out;
}

String _general(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  final abs = v.abs();
  if (abs >= 1e11 || abs < 1e-9) return v.toStringAsExponential(5).replaceAll(RegExp(r'\.?0+e'), 'E').replaceAll('E+', 'E+');
  // Excel's General shows at most 11 significant digits on screen.
  final s = double.parse(v.toStringAsPrecision(11)).toString();
  return s;
}

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/// Converts an Excel serial date to a [DateTime] (1900 or 1904 system).
DateTime excelDate(double serial, {bool date1904 = false}) {
  final days = serial.floor();
  final ms = ((serial - days) * 86400000).round();
  // 1900 system: serial 1 is 1900-01-01, with Excel's fictional 1900-02-29 at 60.
  final base = date1904 ? DateTime.utc(1904, 1, 1) : DateTime.utc(1899, 12, days >= 60 ? 30 : 31);
  return base.add(Duration(days: days, milliseconds: ms));
}

/// Excel serial number for a calendar date.
double excelSerial(DateTime date) {
  final d = DateTime.utc(date.year, date.month, date.day);
  var serial = d.difference(DateTime.utc(1899, 12, 30)).inDays.toDouble();
  if (serial < 61) serial -= 1;
  return serial;
}

String _date(double serial, String code, bool date1904) {
  final dt = excelDate(serial, date1904: date1904);
  final ampm = RegExp(r'AM/PM|A/P', caseSensitive: false).hasMatch(code);
  final out = StringBuffer();
  final tokens = RegExp(r'"[^"]*"|\\.|yyyy|yy|mmmmm|mmmm|mmm|mm|m|dddd|ddd|dd|d|hh|h|ss|s|AM/PM|am/pm|A/P|\.0+|.', caseSensitive: false)
      .allMatches(code)
      .map((m) => m.group(0)!)
      .toList();
  String two(int n) => n.toString().padLeft(2, '0');
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    final lower = t.toLowerCase();
    // "m" means minutes right after an hour or right before seconds.
    bool minuteContext() {
      for (var j = i - 1; j >= 0; j--) {
        final p = tokens[j].toLowerCase();
        if (p.startsWith('h')) return true;
        if (RegExp(r'[dy]').hasMatch(p) || p.startsWith('m')) break;
      }
      for (var j = i + 1; j < tokens.length; j++) {
        final n = tokens[j].toLowerCase();
        if (n.startsWith('s')) return true;
        if (RegExp(r'[dyh]').hasMatch(n) || n.startsWith('m')) break;
      }
      return false;
    }

    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    switch (lower) {
      case 'yyyy':
        out.write(dt.year);
      case 'yy':
        out.write(two(dt.year % 100));
      case 'mmmmm':
        out.write(_months[dt.month - 1][0]);
      case 'mmmm':
        out.write(_months[dt.month - 1]);
      case 'mmm':
        out.write(_months[dt.month - 1].substring(0, 3));
      case 'mm':
        out.write(minuteContext() ? two(dt.minute) : two(dt.month));
      case 'm':
        out.write(minuteContext() ? dt.minute : dt.month);
      case 'dddd':
        out.write(_days[dt.weekday % 7]);
      case 'ddd':
        out.write(_days[dt.weekday % 7].substring(0, 3));
      case 'dd':
        out.write(two(dt.day));
      case 'd':
        out.write(dt.day);
      case 'hh':
        out.write(two(ampm ? hour12 : dt.hour));
      case 'h':
        out.write(ampm ? hour12 : dt.hour);
      case 'ss':
        out.write(two(dt.second));
      case 's':
        out.write(dt.second);
      case 'am/pm':
        out.write(dt.hour < 12 ? 'AM' : 'PM');
      case 'a/p':
        out.write(dt.hour < 12 ? 'A' : 'P');
      default:
        if (t.startsWith('"')) {
          out.write(t.substring(1, t.length - 1));
        } else if (t.startsWith('\\')) {
          out.write(t.substring(1));
        } else if (lower.startsWith('.0')) {
          final frac = (dt.millisecond / 1000).toStringAsFixed(t.length - 1);
          out.write(frac.substring(1));
        } else if (t != '_' && t != '*') {
          out.write(t);
        }
    }
  }
  return out.toString();
}
