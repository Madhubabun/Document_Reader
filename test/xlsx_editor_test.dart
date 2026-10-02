import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:doc_reader/services/ooxml/xlsx_editor.dart';
import 'package:doc_reader/services/ooxml/xlsx_formula.dart';
import 'package:doc_reader/services/ooxml/xlsx_reader.dart';
import 'package:doc_reader/services/ooxml/xlsx_styles.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

String part(List<int> xlsx, String name) => utf8.decode(ZipDecoder().decodeBytes(xlsx).findFile(name)!.content as List<int>);

/// Writes edited files to $XLSX_OUT so they can be opened in Excel or
/// checked with other tools.
void keep(String name, List<int> bytes) {
  final dir = Platform.environment['XLSX_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

void main() {
  group('FormulaEngine', () {
    Object? eval(String f, [Map<String, Object?> cells = const {}]) => FormulaEngine.evaluate(f, (sheet, r, c) {
          return cells['${sheet == null ? '' : '$sheet!'}${XlsxReader.columnName(c)}${r + 1}'];
        });

    test('arithmetic and precedence', () {
      expect(eval('1+2*3'), 7);
      expect(eval('(1+2)*3'), 9);
      expect(eval('2^3^2'), 64); // Excel is left-associative
      expect(eval('-2^2'), 4); // unary minus binds tighter in Excel
      expect(eval('50%'), 0.5);
      expect(eval('"a"&1&TRUE'), 'a1TRUE');
      expect(eval('1/0'), isA<FormulaError>());
    });

    test('references, ranges and functions', () {
      final cells = {'A1': 2.0, 'A2': 3.0, 'A3': 'x', 'B1': 10.0, 'Other!A1': 7.0};
      expect(eval('SUM(A1:A3)', cells), 5);
      expect(eval('AVERAGE(A1:A2)', cells), 2.5);
      expect(eval('COUNT(A1:A3)', cells), 2);
      expect(eval('COUNTA(A1:A4)', cells), 3);
      expect(eval('IF(A1>1,"big","small")', cells), 'big');
      expect(eval('Other!A1+A1', cells), 9);
      expect(eval('ROUND(2.345,2)'), 2.35);
      expect(eval('VLOOKUP(2,A1:B1,2,FALSE)', cells), 10);
      expect(eval('SUMIF(A1:A2,">2")', cells), 3);
      expect(eval('IFERROR(1/0,"oops")'), 'oops');
      expect(eval('LEFT("hello",2)&UPPER("x")'), 'heX');
      expect(() => eval('XLOOKUP(1,A1:A2,B1:B2)'), throwsA(isA<UnsupportedFormula>()));
    });
  });

  group('XlsxStyles number formats', () {
    test('formats common codes', () {
      expect(formatExcelNumber(1234.5, const XlsxCellStyle(numFmtId: 4)), '1,234.50');
      expect(formatExcelNumber(0.256, const XlsxCellStyle(numFmtId: 10)), '25.60%');
      expect(formatExcelNumber(-5, const XlsxCellStyle(numFmtId: 0, numFmt: '#,##0;(#,##0)')), '(5)');
      expect(formatExcelNumber(45000, const XlsxCellStyle(numFmtId: 14)), '15/3/2023');
    });
  });

  group('XlsxEditor', () {
    late XlsxEditor editor;
    setUp(() => editor = XlsxEditor.open(fixture('edit.xlsx')));

    XlsxCell? cell(XlsxEditor e, int sheet, String ref) {
      final (r, c) = XlsxReader.parseCellRef(ref)!;
      return e.sheets[sheet].cell(r, c);
    }

    test('expands shared formulas when opening', () {
      expect(cell(editor, 0, 'D3')!.formula, 'B3*C3');
      expect(cell(editor, 0, 'D4')!.formula, 'B4*C4');
    });

    test('editing a value recalculates dependent cells across sheets', () {
      editor.setCell(0, 1, 1, '20'); // B2
      expect(cell(editor, 0, 'D2')!.value, '50');
      expect(cell(editor, 0, 'D5')!.value, '146');
      expect(cell(editor, 1, 'A1')!.value, '292');
      expect(cell(editor, 1, 'A2')!.value, '25');
      expect(editor.hasChanges, isTrue);
    });

    test('typed input becomes the right kind of cell', () {
      editor.setCell(0, 9, 0, 'hello');
      editor.setCell(0, 9, 1, '1,250');
      editor.setCell(0, 9, 2, '15%');
      editor.setCell(0, 9, 3, '=B10*C10');
      editor.setCell(0, 10, 0, "'007");
      editor.setCell(0, 10, 1, 'true');
      expect(cell(editor, 0, 'A10')!.value, 'hello');
      expect(cell(editor, 0, 'B10')!.isNumber, isTrue);
      expect(cell(editor, 0, 'B10')!.value, '1,250');
      expect(cell(editor, 0, 'C10')!.value, '15%');
      expect(cell(editor, 0, 'D10')!.value, '187.5');
      expect(cell(editor, 0, 'A11')!.value, '007');
      expect(cell(editor, 0, 'B11')!.value, 'TRUE');
    });

    test('undo restores the previous state', () {
      editor.setCell(0, 1, 1, '20');
      editor.setBold(0, [(1, 0)], true);
      expect(cell(editor, 0, 'A2')!.style.bold, isTrue);
      expect(editor.undo(), isTrue);
      expect(cell(editor, 0, 'A2')!.style.bold, isFalse);
      expect(editor.undo(), isTrue);
      expect(cell(editor, 0, 'D2')!.value, '25');
      expect(editor.canUndo, isFalse);
    });

    test('bold and fill add formats without changing existing ones', () {
      final before = part(fixture('edit.xlsx'), 'xl/styles.xml');
      final xfCount = RegExp(r'<xf ').allMatches(before).length;
      editor.setBold(0, [(1, 0), (2, 0)], true);
      editor.setFill(0, [(1, 0)], 'FFC000');
      expect(cell(editor, 0, 'A2')!.style.bold, isTrue);
      expect(cell(editor, 0, 'A2')!.style.fill, 'FFC000');
      expect(cell(editor, 0, 'A3')!.style.fill, isNull);
      expect(cell(editor, 0, 'A1')!.style.bold, isTrue); // untouched
      final after = part(editor.save(), 'xl/styles.xml');
      expect(RegExp(r'<xf ').allMatches(after).length, xfCount + 2);
    });

    test('inserting a row shifts cells, formulas, names and merges', () {
      editor.insertRows(0, 2); // before row 3
      expect(cell(editor, 0, 'A4')!.value, 'Paper');
      expect(cell(editor, 0, 'A3'), isNull);
      expect(cell(editor, 0, 'D4')!.formula, 'B4*C4');
      expect(cell(editor, 0, 'D6')!.formula, 'SUM(D2:D5)');
      expect(cell(editor, 1, 'A1')!.formula, 'Budget!D6*2');
      expect(cell(editor, 1, 'A2')!.formula, 'SUM(Budget!B2:B5)');
      final bytes = editor.save();
      final sheet = part(bytes, 'xl/worksheets/sheet1.xml');
      expect(sheet, contains('<mergeCell ref="A8:B8"/>'));
      expect(sheet, contains('<dimension ref="A1:D8"/>'));
      expect(part(bytes, 'xl/workbook.xml'), contains(r'Budget!$D$2:$D$5'));
    });

    test('deleting a referenced row gives #REF! like Excel', () {
      editor.deleteRows(0, 0); // header row
      expect(cell(editor, 0, 'A1')!.value, 'Pens');
      expect(cell(editor, 0, 'D4')!.formula, 'SUM(D1:D3)');
      editor.deleteRows(0, 0, 3);
      expect(cell(editor, 0, 'D1')!.formula, 'SUM(#REF!)');
    });

    test('inserting and deleting columns shifts formulas and widths', () {
      editor.insertColumns(0, 1); // before B
      expect(cell(editor, 0, 'C2')!.value, '10');
      expect(cell(editor, 0, 'E2')!.formula, 'C2*D2');
      expect(cell(editor, 1, 'A2')!.formula, 'SUM(Budget!C2:C4)');
      expect(part(editor.save(), 'xl/worksheets/sheet1.xml'), contains('<mergeCell ref="A7:C7"/>'));
      editor.deleteColumns(0, 1);
      expect(cell(editor, 0, 'D2')!.formula, 'B2*C2');
      editor.deleteColumns(0, 0);
      expect(part(editor.save(), 'xl/worksheets/sheet1.xml'), isNot(contains('<col ')));
    });

    test('refuses column edits that would break an Excel table', () {
      expect(() => editor.insertColumns(2, 1), throwsA(isA<XlsxEditRefused>()));
      editor.insertRows(2, 5);
      expect(part(editor.save(), 'xl/tables/table1.xml'), contains('ref="A1:B3"'));
      editor.insertRows(2, 1);
      expect(part(editor.save(), 'xl/tables/table1.xml'), contains('ref="A1:B4"'));
    });

    test('adds and renames sheets, updating formulas', () {
      expect(editor.sheetNameProblem('budget'), isNotNull);
      expect(editor.sheetNameProblem('a/b'), isNotNull);
      final i = editor.addSheet();
      expect(editor.sheets[i].name, 'Sheet4');
      editor.setCell(i, 0, 0, "='My Sheet'!B1+1");
      expect(cell(editor, i, 'A1')!.value, '6');
      editor.renameSheet(1, 'Summary');
      expect(cell(editor, i, 'A1')!.formula, 'Summary!B1+1');
      editor.renameSheet(0, 'Q1 Budget');
      expect(cell(editor, 1, 'A1')!.formula, "'Q1 Budget'!D5*2");
      final bytes = editor.save();
      expect(part(bytes, 'xl/workbook.xml'), contains(r"'Q1 Budget'!$D$2:$D$4"));
      expect(part(bytes, '[Content_Types].xml'), contains('/xl/worksheets/sheet4.xml'));
      final reread = XlsxReader.read(bytes);
      expect(reread.sheets.map((s) => s.name), ['Q1 Budget', 'Summary', 'Tbl', 'Sheet4']);
    });

    test('saving copies untouched parts and asks Excel to recalculate', () {
      editor.setCell(0, 1, 1, '20');
      final original = ZipDecoder().decodeBytes(fixture('edit.xlsx'));
      final bytes = editor.save();
      keep('edited.xlsx', bytes);
      final saved = ZipDecoder().decodeBytes(bytes);
      for (final name in ['xl/theme/theme1.xml', 'xl/worksheets/sheet3.xml', 'xl/tables/table1.xml', 'docProps/core.xml']) {
        expect(saved.findFile(name)!.content, original.findFile(name)!.content, reason: name);
      }
      expect(saved.findFile('xl/calcChain.xml'), isNull);
      expect(part(bytes, '[Content_Types].xml'), isNot(contains('calcChain')));
      expect(part(bytes, 'xl/_rels/workbook.xml.rels'), isNot(contains('calcChain')));
      expect(part(bytes, 'xl/workbook.xml'), contains('fullCalcOnLoad="1"'));
      final reread = XlsxReader.read(bytes);
      expect(reread.sheets[0].cell(1, 3)!.value, '50');
    });

    test('a heavily edited workbook stays valid', () {
      editor.insertRows(0, 2, 2);
      editor.insertColumns(0, 0);
      editor.setCell(0, 0, 0, 'Row');
      editor.setBold(0, [(0, 1), (0, 2)], true);
      editor.setFill(0, [(0, 1)], '00B050');
      editor.setFontColor(0, [(0, 1)], 'FFFFFF');
      editor.setAlignment(0, [(0, 2)], 'center');
      editor.deleteRows(0, 5);
      final added = editor.addSheet('Notes');
      editor.setCell(added, 0, 0, '=SUM(Budget!E2:E9)');
      editor.renameSheet(0, 'Budget 2026');
      final bytes = editor.save();
      keep('heavy.xlsx', bytes);
      expect(XlsxReader.read(bytes).sheets.last.cell(0, 0)!.formula, "SUM('Budget 2026'!E2:E9)");
    });
  });
}
