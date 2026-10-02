import 'package:xml/xml.dart';

import 'xml_utils.dart';

class XlsxCell {
  const XlsxCell(this.value, {this.formula, this.isNumber = false});

  /// The cached display value as stored in the file.
  final String value;
  final String? formula;
  final bool isNumber;
}

class XlsxSheet {
  XlsxSheet(this.name, this.cells)
      : rowCount = cells.keys.fold(0, (m, k) => k.$1 + 1 > m ? k.$1 + 1 : m),
        columnCount = cells.keys.fold(0, (m, k) => k.$2 + 1 > m ? k.$2 + 1 : m);

  final String name;

  /// Keyed by zero-based (row, column).
  final Map<(int, int), XlsxCell> cells;
  final int rowCount;
  final int columnCount;

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

    final shared = <String>[];
    final sst = pkg.xml('xl/sharedStrings.xml');
    if (sst != null) {
      for (final si in sst.rootElement.kids('si')) {
        // Rich text runs keep text in r/t; phonetic hints (rPh) are not displayed.
        shared.add(si.deep('t').where((t) => t.parentElement?.name.local != 'rPh').map((t) => t.innerText).join());
      }
    }

    final rels = pkg.relationships(workbookPart);
    final sheets = <XlsxSheet>[];
    final sheetList = workbook.rootElement.kid('sheets');
    for (final s in sheetList?.kids('sheet') ?? const <Never>[]) {
      final target = rels[s.relId];
      final sheetXml = target == null ? null : pkg.xml(target);
      if (sheetXml == null) continue;
      final cells = <(int, int), XlsxCell>{};
      final data = sheetXml.rootElement.kid('sheetData');
      var rowIndex = -1;
      for (final row in data?.kids('row') ?? const <Never>[]) {
        rowIndex = (int.tryParse(row.attr('r') ?? '') ?? rowIndex + 2) - 1;
        var colIndex = -1;
        for (final c in row.kids('c')) {
          final ref = c.attr('r');
          final parsed = ref == null ? null : parseCellRef(ref);
          colIndex = parsed?.$2 ?? colIndex + 1;
          final type = c.attr('t');
          final raw = c.kid('v')?.innerText;
          final formula = c.kid('f')?.innerText;
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
          if (value.isEmpty && (formula == null || formula.isEmpty)) continue;
          final isNumber = (type == null || type == 'n') && raw != null;
          cells[(parsed?.$1 ?? rowIndex, colIndex)] = XlsxCell(
            isNumber ? formatNumber(value) : value,
            formula: (formula == null || formula.isEmpty) ? null : formula,
            isNumber: isNumber,
          );
        }
      }
      sheets.add(XlsxSheet(s.attr('name') ?? 'Sheet ${sheets.length + 1}', cells));
    }
    return XlsxWorkbook(sheets);
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
