import 'dart:typed_data';

import 'ooxml_writer.dart';
import 'xlsx_reader.dart';

/// Writes an [XlsxWorkbook] as a standard .xlsx that opens in Microsoft Excel.
///
/// Text is stored as inline strings, numbers as numbers, and formulas keep
/// their cached value so the sheet looks right before Excel recalculates.
class XlsxWriter {
  static const _main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  static const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  /// [boldFirstRow] styles row 1 as a header.
  static Uint8List write(XlsxWorkbook book, {String title = '', bool boldFirstRow = false}) {
    final pkg = OoxmlPackageWriter();
    final sheets = book.sheets.isEmpty ? [XlsxSheet('Sheet1', const {})] : book.sheets;
    final names = <String>{};
    final sheetXml = StringBuffer();
    final rels = <(String, String, String)>[];
    for (var i = 0; i < sheets.length; i++) {
      final name = uniqueSheetName(sheets[i].name, names);
      sheetXml.write('<sheet name="${OoxmlPackageWriter.esc(name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>');
      rels.add(('rId${i + 1}', OoxmlPackageWriter.relType('worksheet'), 'worksheets/sheet${i + 1}.xml'));
      pkg.addXml('xl/worksheets/sheet${i + 1}.xml', _sheet(sheets[i], boldFirstRow),
          contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml');
    }
    rels.add(('rId${sheets.length + 1}', OoxmlPackageWriter.relType('styles'), 'styles.xml'));
    pkg.addXml('xl/workbook.xml', '<workbook xmlns="$_main" xmlns:r="$_r"><sheets>$sheetXml</sheets></workbook>',
        contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml');
    pkg.addXml('xl/_rels/workbook.xml.rels', OoxmlPackageWriter.rels(rels));
    pkg.addXml('xl/styles.xml', _styles, contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml');
    pkg.addRootRels('xl/workbook.xml');
    pkg.addDocProps(title: title);
    return pkg.build();
  }

  /// Excel sheet names: at most 31 characters, none of `[]:*?/\`, unique.
  static String uniqueSheetName(String raw, Set<String> taken) {
    var name = raw.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
    if (name.isEmpty) name = 'Sheet';
    if (name.length > 31) name = name.substring(0, 31);
    var candidate = name;
    var i = 2;
    while (taken.contains(candidate.toLowerCase())) {
      final suffix = ' ($i)';
      candidate = '${name.length + suffix.length > 31 ? name.substring(0, 31 - suffix.length) : name}$suffix';
      i++;
    }
    taken.add(candidate.toLowerCase());
    return candidate;
  }

  static String _sheet(XlsxSheet sheet, bool boldFirstRow) {
    final byRow = <int, List<(int, XlsxCell)>>{};
    sheet.cells.forEach((key, cell) => byRow.putIfAbsent(key.$1, () => []).add((key.$2, cell)));
    final b = StringBuffer('<worksheet xmlns="$_main" xmlns:r="$_r">');
    if (sheet.columnCount > 0) {
      // Width in characters from the longest value per column, capped.
      final widths = List<int>.filled(sheet.columnCount, 8);
      sheet.cells.forEach((key, cell) {
        final len = cell.value.length + 2;
        if (len > widths[key.$2]) widths[key.$2] = len > 60 ? 60 : len;
      });
      b.write('<cols>');
      for (var c = 0; c < widths.length; c++) {
        b.write('<col min="${c + 1}" max="${c + 1}" width="${widths[c]}" customWidth="1"/>');
      }
      b.write('</cols>');
    }
    b.write('<sheetData>');
    for (final r in byRow.keys.toList()..sort()) {
      b.write('<row r="${r + 1}">');
      final cells = byRow[r]!..sort((a, b) => a.$1.compareTo(b.$1));
      for (final (c, cell) in cells) {
        final ref = '${XlsxReader.columnName(c)}${r + 1}';
        final style = boldFirstRow && r == 0 ? ' s="1"' : '';
        final raw = cell.rawValue;
        final numeric = cell.isNumber && double.tryParse(raw) != null;
        if (cell.formula != null) {
          b.write('<c r="$ref"$style${numeric || raw.isEmpty ? '' : ' t="str"'}><f>${OoxmlPackageWriter.esc(cell.formula!)}</f>'
              '${raw.isEmpty ? '' : '<v>${OoxmlPackageWriter.esc(raw)}</v>'}</c>');
        } else if (numeric) {
          b.write('<c r="$ref"$style><v>$raw</v></c>');
        } else {
          b.write('<c r="$ref"$style t="inlineStr"><is><t xml:space="preserve">${OoxmlPackageWriter.esc(cell.value)}</t></is></c>');
        }
      }
      b.write('</row>');
    }
    b.write('</sheetData></worksheet>');
    return b.toString();
  }

  static const _styles = '<styleSheet xmlns="$_main">'
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>'
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';
}
