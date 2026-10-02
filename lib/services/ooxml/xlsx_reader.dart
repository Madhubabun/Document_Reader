import 'package:xml/xml.dart';

import 'xlsx_styles.dart';
import 'xml_utils.dart';

export 'xlsx_styles.dart' show XlsxCellStyle;

class XlsxCell {
  const XlsxCell(this.value, {this.formula, this.isNumber = false, this.number, this.style = XlsxCellStyle.plain});

  /// The display text: the cached value formatted with the cell's number format.
  final String value;
  final String? formula;
  final bool isNumber;

  /// The stored number behind [value] when [isNumber] (unformatted).
  final double? number;
  final XlsxCellStyle style;

  /// Text to put back into a file: the raw number for numeric cells.
  String get rawValue {
    final n = number;
    if (!isNumber || n == null) return value;
    return n == n.roundToDouble() && n.abs() < 1e15 ? n.toInt().toString() : n.toString();
  }
}

class XlsxSheet {
  XlsxSheet(this.name, this.cells, {this.columnWidths = const {}})
      : rowCount = cells.keys.fold(0, (m, k) => k.$1 + 1 > m ? k.$1 + 1 : m),
        columnCount = cells.keys.fold(0, (m, k) => k.$2 + 1 > m ? k.$2 + 1 : m);

  final String name;

  /// Keyed by zero-based (row, column).
  final Map<(int, int), XlsxCell> cells;
  final int rowCount;
  final int columnCount;

  /// Column widths in Excel character units, for columns that set one.
  final Map<int, double> columnWidths;

  XlsxCell? cell(int row, int col) => cells[(row, col)];
}

class XlsxWorkbook {
  const XlsxWorkbook(this.sheets);

  final List<XlsxSheet> sheets;
}

/// Reads cell values from a .xlsx (SpreadsheetML) workbook.
class XlsxReader {
  static XlsxWorkbook read(List<int> bytes) {
    final pkg = OoxmlPackage(bytes);
    const workbookPart = 'xl/workbook.xml';
    final workbook = pkg.xml(workbookPart);
    if (workbook == null) throw OoxmlFormatException('Not an Excel workbook (xl/workbook.xml missing).');

    final shared = readSharedStrings(pkg.xml('xl/sharedStrings.xml'));
    final styles = XlsxStyles.parse(pkg.xml('xl/styles.xml'));
    final date1904 = workbook.rootElement.kid('workbookPr')?.attr('date1904') == '1';

    final rels = pkg.relationships(workbookPart);
    final sheets = <XlsxSheet>[];
    final sheetList = workbook.rootElement.kid('sheets');
    for (final s in sheetList?.kids('sheet') ?? const <Never>[]) {
      final target = rels[s.relId];
      final sheetXml = target == null ? null : pkg.xml(target);
      if (sheetXml == null) continue;
      sheets.add(readSheet(s.attr('name') ?? 'Sheet ${sheets.length + 1}', sheetXml.rootElement, shared, styles, date1904: date1904));
    }
    return XlsxWorkbook(sheets);
  }

  static List<String> readSharedStrings(XmlDocument? sst) => [
        // Rich text runs keep text in r/t; phonetic hints (rPh) are not displayed.
        for (final si in sst?.rootElement.kids('si') ?? const <XmlElement>[])
          si.deep('t').where((t) => t.parentElement?.name.local != 'rPh').map((t) => t.innerText).join(),
      ];

  /// Reads one worksheet's cells, formats and column widths.
  static XlsxSheet readSheet(String name, XmlElement worksheet, List<String> shared, XlsxStyles styles, {bool date1904 = false}) {
    final cells = <(int, int), XlsxCell>{};
    final data = worksheet.kid('sheetData');
    var rowIndex = -1;
    for (final row in data?.kids('row') ?? const <Never>[]) {
      rowIndex = (int.tryParse(row.attr('r') ?? '') ?? rowIndex + 2) - 1;
      var colIndex = -1;
      for (final c in row.kids('c')) {
        final ref = c.attr('r');
        final parsed = ref == null ? null : parseCellRef(ref);
        colIndex = parsed?.$2 ?? colIndex + 1;
        final cell = readCell(c, shared, styles, date1904: date1904);
        if (cell != null) cells[(parsed?.$1 ?? rowIndex, colIndex)] = cell;
      }
    }
    final widths = <int, double>{};
    for (final col in worksheet.kid('cols')?.kids('col') ?? const <XmlElement>[]) {
      final min = int.tryParse(col.attr('min') ?? '');
      final max = int.tryParse(col.attr('max') ?? '');
      final width = double.tryParse(col.attr('width') ?? '');
      if (min == null || max == null || width == null) continue;
      for (var i = min; i <= max && i <= min + 200; i++) {
        widths[i - 1] = col.attr('hidden') == '1' ? 0 : width;
      }
    }
    return XlsxSheet(name, cells, columnWidths: widths);
  }

  /// One `<c>` element, or null when it holds nothing to show.
  static XlsxCell? readCell(XmlElement c, List<String> shared, XlsxStyles styles, {bool date1904 = false}) {
    final type = c.attr('t');
    final raw = c.kid('v')?.innerText;
    final formula = c.kid('f')?.innerText;
    final style = styles[int.tryParse(c.attr('s') ?? '') ?? 0];
    String value;
    switch (type) {
      case 's':
        final i = int.tryParse(raw ?? '');
        value = (i != null && i >= 0 && i < shared.length) ? shared[i] : '';
      case 'inlineStr':
        value = c.deep('t').map((t) => t.innerText).join();
      case 'b':
        value = raw == '1' ? 'TRUE' : 'FALSE';
      default:
        value = raw ?? '';
    }
    if (value.isEmpty && (formula == null || formula.isEmpty) && style.fill == null) return null;
    final number = (type == null || type == 'n') && raw != null && raw.isNotEmpty ? double.tryParse(raw) : null;
    return XlsxCell(
      number != null ? formatExcelNumber(number, style, date1904: date1904) : value,
      formula: (formula == null || formula.isEmpty) ? null : formula,
      isNumber: number != null,
      number: number,
      style: style,
    );
  }

  /// `B3` -> (2, 1), zero-based (row, column).
  static (int, int)? parseCellRef(String ref) {
    final m = RegExp(r'^\$?([A-Za-z]+)\$?(\d+)$').firstMatch(ref);
    if (m == null) return null;
    return (int.parse(m.group(2)!) - 1, columnIndex(m.group(1)!));
  }

  static int columnIndex(String letters) {
    var n = 0;
    for (final unit in letters.toUpperCase().codeUnits) {
      n = n * 26 + (unit - 64);
    }
    return n - 1;
  }

  static String columnName(int index) {
    var n = index + 1;
    final buf = StringBuffer();
    while (n > 0) {
      final r = (n - 1) % 26;
      buf.write(String.fromCharCode(65 + r));
      n = (n - 1) ~/ 26;
    }
    return buf.toString().split('').reversed.join();
  }

  /// Trims float noise such as 0.30000000000000004 that Excel would hide.
  static String formatNumber(String raw) {
    final d = double.tryParse(raw);
    if (d == null) return raw;
    if (d == d.roundToDouble() && d.abs() < 1e15) return d.toInt().toString();
    final s = double.parse(d.toStringAsPrecision(12)).toString();
    return s;
  }
}
