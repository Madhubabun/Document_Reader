import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'ooxml_writer.dart';
import 'xlsx_formula.dart';
import 'xlsx_reader.dart';
import 'xlsx_styles.dart';
import 'xml_utils.dart';

/// Thrown when an edit would damage something the app can't safely update
/// (for example inserting a column through an Excel table).
class XlsxEditRefused implements Exception {
  const XlsxEditRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Sheet {
  _Sheet(this.element, this.part, this.doc);

  /// The `<sheet>` entry in workbook.xml.
  final XmlElement element;
  final String part;
  final XmlDocument doc;

  String get name => element.attr('name') ?? '';
}

/// Edits an .xlsx file in place.
///
/// Only the XML parts an edit touches are rewritten; every other part of the
/// package (charts, pictures, pivot tables, macros-free extensions, custom
/// XML, themes) is copied byte for byte, so the file keeps everything Excel
/// put in it. Cell formats are preserved, new formats are appended to the
/// existing style sheet, and the workbook asks Excel to recalculate on open.
class XlsxEditor {
  XlsxEditor._(this._archive);

  static const _relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const _sheetType = '$_relNs/worksheet';
  static const _sheetContentType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml';
  static const _workbookPart = 'xl/workbook.xml';
  static const _maxUndo = 30;

  final Archive _archive;
  final _docs = <String, XmlDocument>{};
  final _dirty = <String>{};
  final _removed = <String>{};
  final _undo = <_State>[];
  final _styleCache = <String, int>{};
  late List<_Sheet> _sheets;
  late List<String> _shared;
  late XlsxStyles _styles;
  late bool _date1904;
  late List<XlsxSheet> _snapshots;

  /// True once any edit has been made since opening or the last [markSaved].
  bool get hasChanges => _version != _savedVersion;
  int _version = 0;
  int _savedVersion = 0;
  bool get canUndo => _undo.isNotEmpty;

  /// Current contents for display, one entry per sheet.
  List<XlsxSheet> get sheets => _snapshots;
  XlsxWorkbook get workbook => XlsxWorkbook(_snapshots);

  static XlsxEditor open(List<int> bytes) {
    final editor = XlsxEditor._(ZipDecoder().decodeBytes(bytes));
    editor._load();
    return editor;
  }

  void _load() {
    final wb = _doc(_workbookPart);
    if (wb == null) throw OoxmlFormatException('Not an Excel workbook (xl/workbook.xml missing).');
    _date1904 = wb.rootElement.kid('workbookPr')?.attr('date1904') == '1';
    _shared = XlsxReader.readSharedStrings(_doc('xl/sharedStrings.xml'));
    _indexSheets();
    for (final s in _sheets) {
      _normalize(s);
    }
    _styles = XlsxStyles.parse(_doc(_stylesPart));
    _refresh();
  }

  // ---------------------------------------------------------------------------
  // Package plumbing

  XmlDocument? _doc(String path) {
    final cached = _docs[path];
    if (cached != null) return cached;
    if (_removed.contains(path)) return null;
    final file = _archive.findFile(path);
    if (file == null) return null;
    final doc = XmlDocument.parse(utf8.decode(file.content as List<int>, allowMalformed: true));
    _docs[path] = doc;
    return doc;
  }

  XmlDocument get _workbook => _doc(_workbookPart)!;

  static String _relsPath(String part) {
    final slash = part.lastIndexOf('/');
    return '${part.substring(0, slash + 1)}_rels/${part.substring(slash + 1)}.rels';
  }

  Map<String, XmlElement> _relationships(String part) {
    final rels = _doc(_relsPath(part));
    return {
      for (final r in rels?.rootElement.kids('Relationship') ?? const <XmlElement>[])
        if (r.attr('Id') != null) r.attr('Id')!: r,
    };
  }

  String _target(String part, XmlElement rel) {
    final slash = part.lastIndexOf('/');
    return OoxmlPackage.resolvePath(slash < 0 ? '' : part.substring(0, slash), rel.attr('Target') ?? '');
  }

  String get _stylesPart {
    for (final r in _relationships(_workbookPart).values) {
      if ((r.attr('Type') ?? '').endsWith('/styles')) return _target(_workbookPart, r);
    }
    return 'xl/styles.xml';
  }

  void _indexSheets() {
    final rels = _relationships(_workbookPart);
    _sheets = [];
    for (final el in _workbook.rootElement.kid('sheets')?.kids('sheet') ?? const <XmlElement>[]) {
      final rel = rels[el.relId];
      if (rel == null || !(rel.attr('Type') ?? '').endsWith('/worksheet')) continue;
      final part = _target(_workbookPart, rel);
      final doc = _doc(part);
      if (doc != null) _sheets.add(_Sheet(el, part, doc));
    }
  }

  XmlName _name(XmlElement context, String local) => XmlName.parts(local, prefix: context.name.prefix);

  XmlElement _el(XmlElement context, String local, [Map<String, String> attrs = const {}]) =>
      XmlElement(_name(context, local), [for (final e in attrs.entries) XmlAttribute(XmlName.parts(e.key), e.value)]);

  // ---------------------------------------------------------------------------
  // Undo

  void _checkpoint() {
    _version++;
    _undo.add(_State(
      {for (final e in _docs.entries) e.key: e.value.toXmlString()},
      {..._dirty},
      {..._removed},
    ));
    if (_undo.length > _maxUndo) _undo.removeAt(0);
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    final state = _undo.removeLast();
    _version++;
    _docs
      ..clear()
      ..addAll({for (final e in state.docs.entries) e.key: XmlDocument.parse(e.value)});
    _dirty
      ..clear()
      ..addAll(state.dirty);
    _removed
      ..clear()
      ..addAll(state.removed);
    _styleCache.clear();
    _indexSheets();
    _styles = XlsxStyles.parse(_doc(_stylesPart));
    _refresh();
    return true;
  }

  // ---------------------------------------------------------------------------
  // Normalising a sheet so it can be edited safely

  /// Gives every row and cell an explicit reference and expands shared
  /// formulas into ordinary ones, so cells can move and change independently.
  void _normalize(_Sheet sheet) {
    final data = sheet.doc.rootElement.kid('sheetData');
    if (data == null) return;
    var rowIndex = 0;
    final masters = <String, (String, int, int)>{};
    final children = <(XmlElement, String, int, int)>[];
    for (final row in data.kids('row')) {
      rowIndex = int.tryParse(row.attr('r') ?? '') ?? rowIndex + 1;
      row.setAttribute('r', '$rowIndex');
      var col = 0;
      for (final c in row.kids('c')) {
        final parsed = XlsxReader.parseCellRef(c.attr('r') ?? '');
        if (parsed == null) {
          c.setAttribute('r', '${XlsxReader.columnName(col)}$rowIndex');
        }
        final ref = XlsxReader.parseCellRef(c.attr('r')!)!;
        col = ref.$2 + 1;
        final f = c.kid('f');
        if (f != null && f.attr('t') == 'shared') {
          final si = f.attr('si') ?? '';
          if (f.innerText.trim().isNotEmpty) {
            masters[si] = (f.innerText, ref.$1, ref.$2);
          } else {
            children.add((f, si, ref.$1, ref.$2));
          }
        }
      }
    }
    for (final (f, si, r, c) in children) {
      final master = masters[si];
      if (master == null) continue;
      f.innerText = translateFormula(master.$1, r - master.$2, c - master.$3);
      f.removeAttribute('t');
      f.removeAttribute('si');
    }
    for (final f in data.deep('f')) {
      if (f.attr('t') == 'shared') {
        f.removeAttribute('t');
        f.removeAttribute('si');
        f.removeAttribute('ref');
      }
    }
  }

  /// Moves the relative parts of every reference by ([dRow], [dCol]), as
  /// Excel does when a formula is copied.
  static String translateFormula(String formula, int dRow, int dCol) => mapFormulaRefs(formula, (ref) {
        final r = ref.rowAbs ? ref.row : ref.row + dRow;
        final c = ref.colAbs ? ref.col : ref.col + dCol;
        if (r < 0 || c < 0 || r > 1048575 || c > 16383) return null;
        return FormulaRef(row: r, col: c, rowAbs: ref.rowAbs, colAbs: ref.colAbs).a1;
      });

  // ---------------------------------------------------------------------------
  // Reading values back for display and formulas

  void _refresh() {
    _snapshots = [
      for (final s in _sheets) XlsxReader.readSheet(s.name, s.doc.rootElement, _shared, _styles, date1904: _date1904),
    ];
  }

  XmlElement? _row(_Sheet sheet, int r, {bool create = false}) {
    final data = sheet.doc.rootElement.kid('sheetData');
    if (data == null) {
      if (!create) return null;
      final created = _el(sheet.doc.rootElement, 'sheetData');
      _insertSheetChild(sheet, created);
      return _row(sheet, r, create: true);
    }
    XmlElement? before;
    for (final row in data.kids('row')) {
      final n = int.parse(row.attr('r')!) - 1;
      if (n == r) return row;
      if (n > r) {
        before = row;
        break;
      }
    }
    if (!create) return null;
    final row = _el(data, 'row', {'r': '${r + 1}'});
    if (before == null) {
      data.children.add(row);
    } else {
      data.children.insert(data.children.indexOf(before), row);
    }
    return row;
  }

  /// Puts a new top-level worksheet element in schema order.
  void _insertSheetChild(_Sheet sheet, XmlElement child) {
    const order = [
      'sheetPr', 'dimension', 'sheetViews', 'sheetFormatPr', 'cols', 'sheetData', 'sheetCalcPr', 'sheetProtection', //
      'protectedRanges', 'scenarios', 'autoFilter', 'sortState', 'dataConsolidate', 'customSheetViews', 'mergeCells',
      'phoneticPr', 'conditionalFormatting', 'dataValidations', 'hyperlinks', 'printOptions', 'pageMargins', 'pageSetup',
      'headerFooter', 'rowBreaks', 'colBreaks', 'customProperties', 'cellWatches', 'ignoredErrors', 'smartTags', 'drawing',
      'legacyDrawing', 'legacyDrawingHF', 'picture', 'oleObjects', 'controls', 'webPublishItems', 'tableParts', 'extLst',
    ];
    final root = sheet.doc.rootElement;
    final rank = order.indexOf(child.name.local);
    for (final existing in root.childElements) {
      if (order.indexOf(existing.name.local) > rank) {
        root.children.insert(root.children.indexOf(existing), child);
        return;
      }
    }
    root.children.add(child);
  }

  XmlElement? _cell(_Sheet sheet, int r, int c, {bool create = false}) {
    final row = _row(sheet, r, create: create);
    if (row == null) return null;
    XmlElement? before;
    for (final cell in row.kids('c')) {
      final ref = XlsxReader.parseCellRef(cell.attr('r')!)!;
      if (ref.$2 == c) return cell;
      if (ref.$2 > c) {
        before = cell;
        break;
      }
    }
    if (!create) return null;
    final cell = _el(row, 'c', {'r': '${XlsxReader.columnName(c)}${r + 1}'});
    // Inherit the row's or column's default format, as Excel does.
    final rowStyle = row.attr('customFormat') == '1' ? row.attr('s') : null;
    final colStyle = _columnStyle(sheet, c);
    final style = rowStyle ?? colStyle;
    if (style != null && style != '0') cell.setAttribute('s', style);
    if (before == null) {
      row.children.add(cell);
    } else {
      row.children.insert(row.children.indexOf(before), cell);
    }
    row.removeAttribute('spans');
    return cell;
  }

  String? _columnStyle(_Sheet sheet, int c) {
    for (final col in sheet.doc.rootElement.kid('cols')?.kids('col') ?? const <XmlElement>[]) {
      final min = int.tryParse(col.attr('min') ?? '') ?? 0;
      final max = int.tryParse(col.attr('max') ?? '') ?? 0;
      if (c + 1 >= min && c + 1 <= max) return col.attr('style');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Cell edits

  /// Sets a cell from what the user typed: `=` starts a formula, numbers
  /// (with thousands separators or %) are stored as numbers, TRUE/FALSE as
  /// booleans, a leading apostrophe forces text, and empty clears the cell.
  void setCell(int sheetIndex, int row, int col, String input) {
    _checkpoint();
    _setCell(_sheets[sheetIndex], row, col, input);
    _afterEdit({_sheets[sheetIndex].part});
  }

  void clearCells(int sheetIndex, Iterable<(int, int)> cells) {
    _checkpoint();
    for (final (r, c) in cells) {
      _setCell(_sheets[sheetIndex], r, c, '');
    }
    _afterEdit({_sheets[sheetIndex].part});
  }

  void _setCell(_Sheet sheet, int row, int col, String input) {
    if (input.isEmpty) {
      final cell = _cell(sheet, row, col);
      if (cell == null) return;
      final style = cell.attr('s');
      if (style == null || style == '0') {
        final parent = cell.parentElement!;
        cell.remove();
        if (parent.childElements.isEmpty && parent.attributes.length <= 2) parent.remove();
      } else {
        _clearContent(cell);
      }
      return;
    }
    final cell = _cell(sheet, row, col, create: true)!;
    _clearContent(cell);
    if (input.startsWith('=') && input.length > 1) {
      cell.children.add(XmlElement(_name(cell, 'f'), [], [XmlText(input.substring(1))]));
      return;
    }
    if (input.startsWith("'")) {
      _writeInlineString(cell, input.substring(1));
      return;
    }
    final upper = input.trim().toUpperCase();
    if (upper == 'TRUE' || upper == 'FALSE') {
      cell.setAttribute('t', 'b');
      cell.children.add(XmlElement(_name(cell, 'v'), [], [XmlText(upper == 'TRUE' ? '1' : '0')]));
      return;
    }
    final date = _parseDate(input.trim());
    if (date != null) {
      final base = int.tryParse(cell.attr('s') ?? '') ?? 0;
      if (!_styles[base].isDate) cell.setAttribute('s', '${_deriveStyle(base, numFmtId: 14)}');
      cell.children.add(XmlElement(_name(cell, 'v'), [], [XmlText(_numberText(excelSerial(date) - (_date1904 ? 1462 : 0)))]));
      return;
    }
    final number = RegExp(r'^\s*([+-]?)(\d{1,3}(?:,\d{3})+|\d*)(\.\d+)?\s*(%?)\s*$').firstMatch(input);
    if (number != null && (number.group(2)!.isNotEmpty || number.group(3) != null)) {
      var value = double.parse('${number.group(1)}${number.group(2)!.replaceAll(',', '')}${number.group(3) ?? ''}'.replaceFirst(RegExp(r'^([+-]?)$'), r'${1}0'));
      final style = _styles[int.tryParse(cell.attr('s') ?? '') ?? 0];
      if (number.group(4) == '%') {
        value /= 100;
        if (style.formatCode == null) {
          final decimals = number.group(3) == null ? 9 : 10;
          cell.setAttribute('s', '${_deriveStyle(int.tryParse(cell.attr('s') ?? '') ?? 0, numFmtId: decimals)}');
        }
      } else if (number.group(2)!.contains(',') && style.formatCode == null) {
        cell.setAttribute('s', '${_deriveStyle(int.tryParse(cell.attr('s') ?? '') ?? 0, numFmtId: number.group(3) == null ? 3 : 4)}');
      }
      cell.children.add(XmlElement(_name(cell, 'v'), [], [XmlText(_numberText(value))]));
      return;
    }
    _writeInlineString(cell, input);
  }

  /// Dates typed as d/m/yyyy, d-m-yyyy or yyyy-mm-dd, matching how the
  /// app shows them.
  static DateTime? _parseDate(String text) {
    int? y, m, d;
    final dmy = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4}|\d{2})$').firstMatch(text);
    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text);
    if (dmy != null) {
      d = int.parse(dmy.group(1)!);
      m = int.parse(dmy.group(2)!);
      y = int.parse(dmy.group(3)!);
      if (dmy.group(3)!.length == 2) y += y < 30 ? 2000 : 1900;
    } else if (iso != null) {
      y = int.parse(iso.group(1)!);
      m = int.parse(iso.group(2)!);
      d = int.parse(iso.group(3)!);
    } else {
      return null;
    }
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    final date = DateTime.utc(y, m, d);
    return date.month == m ? date : null;
  }

  void _clearContent(XmlElement cell) {
    cell.removeAttribute('t');
    cell.children.removeWhere((n) => n is XmlElement && const {'f', 'v', 'is'}.contains(n.name.local));
  }

  void _writeInlineString(XmlElement cell, String text) {
    cell.setAttribute('t', 'inlineStr');
    final t = XmlElement(_name(cell, 't'), [XmlAttribute(XmlName.parts('space', prefix: 'xml'), 'preserve')], [XmlText(text)]);
    cell.children.add(XmlElement(_name(cell, 'is'), [], [t]));
  }

  static String _numberText(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

  /// Makes the given cells bold (or not bold).
  void setBold(int sheetIndex, Iterable<(int, int)> cells, bool bold) => _restyle(sheetIndex, cells, (s) => _deriveStyle(s, bold: bold));

  void setItalic(int sheetIndex, Iterable<(int, int)> cells, bool italic) => _restyle(sheetIndex, cells, (s) => _deriveStyle(s, italic: italic));

  /// Fills the given cells with an RGB colour, or removes the fill for null.
  void setFill(int sheetIndex, Iterable<(int, int)> cells, String? rgb) => _restyle(sheetIndex, cells, (s) => _deriveStyle(s, fill: rgb ?? ''));

  void setFontColor(int sheetIndex, Iterable<(int, int)> cells, String? rgb) => _restyle(sheetIndex, cells, (s) => _deriveStyle(s, fontColor: rgb ?? ''));

  void setAlignment(int sheetIndex, Iterable<(int, int)> cells, String? horizontal) =>
      _restyle(sheetIndex, cells, (s) => _deriveStyle(s, align: horizontal ?? ''));

  void _restyle(int sheetIndex, Iterable<(int, int)> cells, int Function(int style) derive) {
    _checkpoint();
    final sheet = _sheets[sheetIndex];
    for (final (r, c) in cells) {
      final cell = _cell(sheet, r, c, create: true)!;
      final next = derive(int.tryParse(cell.attr('s') ?? '') ?? 0);
      if (next == 0) {
        cell.removeAttribute('s');
      } else {
        cell.setAttribute('s', '$next');
      }
    }
    _dirty.add(sheet.part);
    _styles = XlsxStyles.parse(_doc(_stylesPart));
    _refresh();
  }

  XmlDocument _stylesDoc() {
    final existing = _doc(_stylesPart);
    if (existing != null) return existing;
    // Rare: a workbook without a style sheet. Add Excel's minimal one.
    const ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    final doc = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="$ns"><fonts count="1"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>');
    const path = 'xl/styles.xml';
    _docs[path] = doc;
    _dirty.add(path);
    _addRelationship(_workbookPart, '$_relNs/styles', 'styles.xml');
    _addOverride('/$path', 'application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml');
    return doc;
  }

  /// Appends a copy of cell format [base] with the given changes to the
  /// style sheet and returns its index. Empty strings remove a fill/colour.
  int _deriveStyle(int base, {bool? bold, bool? italic, String? fill, String? fontColor, String? align, int? numFmtId}) {
    final key = '$base|$bold|$italic|$fill|$fontColor|$align|$numFmtId';
    final cached = _styleCache[key];
    if (cached != null) return cached;
    final doc = _stylesDoc();
    final root = doc.rootElement;
    final cellXfs = root.kid('cellXfs')!;
    final xfs = cellXfs.kids('xf').toList();
    final xf = (base < xfs.length ? xfs[base] : xfs.first).copy();

    XmlElement list(String name) {
      var el = root.kid(name);
      if (el == null) {
        el = _el(root, name, {'count': '0'});
        // Keep schema order: numFmts, fonts, fills, borders, ...
        final numFmts = root.kid('numFmts');
        final fonts = root.kid('fonts');
        final after = name == 'fills' ? (fonts ?? numFmts) : numFmts;
        root.children.insert(after == null ? 0 : root.children.indexOf(after) + 1, el);
      }
      return el;
    }

    int append(XmlElement parent, XmlElement child) {
      parent.children.add(child);
      final count = parent.childElements.where((e) => e.name.local == child.name.local).length;
      parent.setAttribute('count', '$count');
      return count - 1;
    }

    if (bold != null || italic != null || fontColor != null) {
      final fonts = list('fonts');
      final all = fonts.kids('font').toList();
      final fontId = int.tryParse(xf.attr('fontId') ?? '') ?? 0;
      final font = (fontId < all.length ? all[fontId] : all.isEmpty ? _el(fonts, 'font') : all.first).copy();
      // CT_Font children are a sequence starting b, i, strike; color comes after sz.
      if (bold != null) {
        font.children.removeWhere((n) => n is XmlElement && n.name.local == 'b');
        if (bold) font.children.insert(0, _el(font, 'b'));
      }
      if (italic != null) {
        font.children.removeWhere((n) => n is XmlElement && n.name.local == 'i');
        if (italic) {
          final b = font.kid('b');
          font.children.insert(b == null ? 0 : font.children.indexOf(b) + 1, _el(font, 'i'));
        }
      }
      if (fontColor != null) {
        font.children.removeWhere((n) => n is XmlElement && n.name.local == 'color');
        if (fontColor.isNotEmpty) {
          final color = _el(font, 'color', {'rgb': 'FF$fontColor'});
          final anchor = font.kid('sz');
          if (anchor != null) {
            font.children.insert(font.children.indexOf(anchor) + 1, color);
          } else {
            final name = font.kid('name');
            font.children.insert(name == null ? font.children.length : font.children.indexOf(name), color);
          }
        }
      }
      xf.setAttribute('fontId', '${append(fonts, font)}');
      xf.setAttribute('applyFont', '1');
    }
    if (fill != null) {
      if (fill.isEmpty) {
        xf.setAttribute('fillId', '0');
      } else {
        final fills = list('fills');
        final f = _el(fills, 'fill');
        final pattern = _el(fills, 'patternFill', {'patternType': 'solid'});
        pattern.children
          ..add(_el(fills, 'fgColor', {'rgb': 'FF$fill'}))
          ..add(_el(fills, 'bgColor', {'indexed': '64'}));
        f.children.add(pattern);
        xf.setAttribute('fillId', '${append(fills, f)}');
      }
      xf.setAttribute('applyFill', '1');
    }
    if (align != null) {
      xf.children.removeWhere((n) => n is XmlElement && n.name.local == 'alignment');
      if (align.isNotEmpty) {
        xf.children.insert(0, _el(xf, 'alignment', {'horizontal': align}));
        xf.setAttribute('applyAlignment', '1');
      }
    }
    if (numFmtId != null) {
      xf.setAttribute('numFmtId', '$numFmtId');
      xf.setAttribute('applyNumberFormat', '1');
    }
    final index = append(cellXfs, xf);
    _dirty.add(_stylesPart);
    _styleCache[key] = index;
    return index;
  }

  // ---------------------------------------------------------------------------
  // Rows and columns

  void insertRows(int sheetIndex, int at, [int count = 1]) => _shift(sheetIndex, rows: true, at: at, delta: count);

  void deleteRows(int sheetIndex, int at, [int count = 1]) => _shift(sheetIndex, rows: true, at: at, delta: -count);

  void insertColumns(int sheetIndex, int at, [int count = 1]) => _shift(sheetIndex, rows: false, at: at, delta: count);

  void deleteColumns(int sheetIndex, int at, [int count = 1]) => _shift(sheetIndex, rows: false, at: at, delta: -count);

  void _shift(int sheetIndex, {required bool rows, required int at, required int delta}) {
    final sheet = _sheets[sheetIndex];
    _guardTables(sheet, rows: rows, at: at, delta: delta);
    _checkpoint();
    final n = delta.abs();
    final deleting = delta < 0;

    int? move(int index) {
      if (deleting) {
        if (index >= at && index < at + n) return null;
        return index >= at + n ? index - n : index;
      }
      return index >= at ? index + n : index;
    }

    FormulaRef? moveRef(FormulaRef ref) {
      final i = move(rows ? ref.row : ref.col);
      if (i == null) return null;
      return FormulaRef(row: rows ? i : ref.row, col: rows ? ref.col : i, rowAbs: ref.rowAbs, colAbs: ref.colAbs);
    }

    String? moveRange(FormulaRef a, FormulaRef b) {
      final lo = rows ? (a.row < b.row ? a.row : b.row) : (a.col < b.col ? a.col : b.col);
      final hi = rows ? (a.row > b.row ? a.row : b.row) : (a.col > b.col ? a.col : b.col);
      int newLo, newHi;
      if (deleting) {
        newLo = lo >= at + n ? lo - n : (lo >= at ? at : lo);
        newHi = hi >= at + n ? hi - n : (hi >= at ? at - 1 : hi);
        if (newHi < newLo) return null;
      } else {
        newLo = lo >= at ? lo + n : lo;
        newHi = hi >= at ? hi + n : hi;
      }
      FormulaRef with_(FormulaRef r, int i) => FormulaRef(row: rows ? i : r.row, col: rows ? r.col : i, rowAbs: r.rowAbs, colAbs: r.colAbs);
      final first = (rows ? a.row <= b.row : a.col <= b.col) ? a : b;
      final second = identical(first, a) ? b : a;
      return '${with_(first, newLo).a1}:${with_(second, newHi).a1}';
    }

    bool isThis(String? name) => name != null && name.toLowerCase() == sheet.name.toLowerCase();

    String mapFormula(String f, {required bool sameSheet}) => mapFormulaRefs(
          f,
          (ref) => (ref.sheet == null ? sameSheet : isThis(ref.sheet)) ? moveRef(ref)?.a1 : ref.a1,
          mapRange: (a, b) => (a.sheet == null ? sameSheet : isThis(a.sheet)) ? moveRange(a, b) : '${a.a1}:${b.a1}',
        );

    // 1. Cells and rows of this sheet.
    final data = sheet.doc.rootElement.kid('sheetData');
    for (final row in data?.kids('row').toList() ?? const <XmlElement>[]) {
      final r = int.parse(row.attr('r')!) - 1;
      if (rows) {
        final nr = move(r);
        if (nr == null) {
          row.remove();
          continue;
        }
        row.setAttribute('r', '${nr + 1}');
        for (final c in row.kids('c')) {
          final ref = XlsxReader.parseCellRef(c.attr('r')!)!;
          c.setAttribute('r', '${XlsxReader.columnName(ref.$2)}${nr + 1}');
        }
      } else {
        row.removeAttribute('spans');
        for (final c in row.kids('c').toList()) {
          final ref = XlsxReader.parseCellRef(c.attr('r')!)!;
          final nc = move(ref.$2);
          if (nc == null) {
            c.remove();
          } else {
            c.setAttribute('r', '${XlsxReader.columnName(nc)}${r + 1}');
          }
        }
      }
    }

    // 2. Column widths and formats.
    if (!rows) _shiftCols(sheet, at, delta);

    // 3. Formulas everywhere that point at this sheet.
    for (final other in _sheets) {
      final same = identical(other, sheet);
      var changed = same;
      for (final f in other.doc.rootElement.deep('f')) {
        final next = mapFormula(f.innerText, sameSheet: same);
        if (next != f.innerText) {
          f.innerText = next;
          changed = true;
        }
      }
      if (changed) _dirty.add(other.part);
    }
    for (final name in _workbook.rootElement.kid('definedNames')?.kids('definedName') ?? const <XmlElement>[]) {
      final next = mapFormula(name.innerText, sameSheet: false);
      if (next != name.innerText) {
        name.innerText = next;
        _dirty.add(_workbookPart);
      }
    }
    _mapChartFormulas((f) => mapFormula(f, sameSheet: false));

    // 4. Ranges stored in attributes and rule formulas of this sheet.
    for (final el in sheet.doc.rootElement.descendantElements.toList()) {
      if (el.name.local == 'c' || el.name.local == 'row') continue;
      for (final attr in const ['ref', 'sqref', 'activeCell', 'topLeftCell']) {
        final value = el.attr(attr);
        if (value == null) continue;
        final parts = value.split(' ').where((p) => p.isNotEmpty).map((p) => mapFormula(p, sameSheet: true)).where((p) => !p.contains('#REF!')).toList();
        if (parts.isEmpty) {
          if (const {'mergeCell', 'hyperlink', 'conditionalFormatting', 'dataValidation', 'protectedRange'}.contains(el.name.local)) {
            el.remove();
          }
        } else {
          el.setAttribute(attr, parts.join(' '));
        }
      }
      if (const {'formula', 'formula1', 'formula2'}.contains(el.name.local)) {
        el.innerText = mapFormula(el.innerText, sameSheet: true);
      }
    }
    for (final container in const ['mergeCells', 'conditionalFormatting', 'dataValidations', 'hyperlinks']) {
      for (final el in sheet.doc.rootElement.kids(container).toList()) {
        if (el.childElements.isEmpty && container != 'conditionalFormatting') {
          el.remove();
        } else if (el.attr('count') != null) {
          el.setAttribute('count', '${el.childElements.length}');
        }
      }
    }
    _shiftTables(sheet, (r) => mapFormula(r, sameSheet: true));
    _afterEdit({sheet.part});
  }

  void _shiftCols(_Sheet sheet, int at, int delta) {
    final cols = sheet.doc.rootElement.kid('cols');
    if (cols == null) return;
    final n = delta.abs();
    for (final col in cols.kids('col').toList()) {
      var min = (int.tryParse(col.attr('min') ?? '') ?? 1) - 1;
      var max = (int.tryParse(col.attr('max') ?? '') ?? 1) - 1;
      if (delta > 0) {
        if (min >= at) {
          min += n;
          max += n;
        } else if (max >= at) {
          max += n;
        }
      } else {
        final end = at + n; // first column after the deleted block
        final keepBefore = min < at ? (max < at ? max : at - 1) - min + 1 : 0;
        final keepAfter = max >= end ? max - (min > end ? min : end) + 1 : 0;
        if (keepBefore + keepAfter == 0) {
          col.remove();
          continue;
        }
        min = min < at ? min : (min >= end ? min - n : at);
        max = min + keepBefore + keepAfter - 1;
      }
      if (max > 16383) max = 16383;
      col.setAttribute('min', '${min + 1}');
      col.setAttribute('max', '${max + 1}');
    }
    if (cols.childElements.isEmpty) cols.remove();
  }

  Iterable<(String, XmlDocument)> _tables(_Sheet sheet) sync* {
    for (final rel in _relationships(sheet.part).values) {
      if (!(rel.attr('Type') ?? '').endsWith('/table')) continue;
      final part = _target(sheet.part, rel);
      final doc = _doc(part);
      if (doc != null) yield (part, doc);
    }
  }

  void _guardTables(_Sheet sheet, {required bool rows, required int at, required int delta}) {
    for (final (_, table) in _tables(sheet)) {
      final ref = table.rootElement.attr('ref');
      final parts = ref?.split(':');
      if (parts == null || parts.length != 2) continue;
      final a = XlsxReader.parseCellRef(parts[0]);
      final b = XlsxReader.parseCellRef(parts[1]);
      if (a == null || b == null) continue;
      final lo = rows ? a.$1 : a.$2;
      final hi = rows ? b.$1 : b.$2;
      final touchesStart = delta > 0 ? at > lo && at <= hi : at <= hi && at + (-delta) > lo;
      if (!rows && touchesStart) {
        throw const XlsxEditRefused('This column is part of an Excel table. Insert or delete table columns in Excel so the table stays intact.');
      }
      if (rows && delta < 0 && at <= lo && at - delta > lo) {
        throw const XlsxEditRefused("This would delete an Excel table's header row. Delete the table in Excel instead.");
      }
    }
  }

  void _shiftTables(_Sheet sheet, String Function(String) map) {
    for (final (part, table) in _tables(sheet)) {
      var changed = false;
      for (final el in [table.rootElement, ...table.rootElement.descendantElements]) {
        final ref = el.attr('ref');
        if (ref == null) continue;
        final next = map(ref);
        if (next != ref && !next.contains('#REF!')) {
          el.setAttribute('ref', next);
          changed = true;
        }
      }
      if (changed) _dirty.add(part);
    }
  }

  void _mapChartFormulas(String Function(String) map) {
    for (final file in _archive.files) {
      if (!RegExp(r'^xl/charts/chart\d+\.xml$').hasMatch(file.name)) continue;
      final doc = _doc(file.name);
      if (doc == null) continue;
      var changed = false;
      for (final f in doc.rootElement.deep('f')) {
        final next = map(f.innerText);
        if (next != f.innerText) {
          f.innerText = next;
          changed = true;
        }
      }
      if (changed) _dirty.add(file.name);
    }
  }

  // ---------------------------------------------------------------------------
  // Sheets

  /// Excel sheet name rules: 1-31 characters, none of `[]:*?/\`, not
  /// starting or ending with an apostrophe, unique ignoring case.
  String? sheetNameProblem(String name, {int? except}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Enter a name.';
    if (trimmed.length > 31) return 'Sheet names can be at most 31 characters.';
    if (RegExp(r'[\[\]:*?/\\]').hasMatch(trimmed)) return r'Sheet names cannot contain [ ] : * ? / \';
    if (trimmed.startsWith("'") || trimmed.endsWith("'")) return 'Sheet names cannot start or end with an apostrophe.';
    if (trimmed.toLowerCase() == 'history') return '"History" is reserved by Excel.';
    for (var i = 0; i < _sheets.length; i++) {
      if (i != except && _sheets[i].name.toLowerCase() == trimmed.toLowerCase()) return 'Another sheet already has this name.';
    }
    return null;
  }

  /// Adds an empty sheet at the end and returns its index.
  int addSheet([String? name]) {
    var title = name?.trim();
    if (title == null || title.isEmpty) {
      var i = _sheets.length + 1;
      while (sheetNameProblem('Sheet$i') != null) {
        i++;
      }
      title = 'Sheet$i';
    }
    final problem = sheetNameProblem(title);
    if (problem != null) throw XlsxEditRefused(problem);
    _checkpoint();
    var n = 1;
    while (_archive.findFile('xl/worksheets/sheet$n.xml') != null || _docs.containsKey('xl/worksheets/sheet$n.xml')) {
      n++;
    }
    final part = 'xl/worksheets/sheet$n.xml';
    final ns = _workbook.rootElement.name.namespaceUri ?? 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    final doc = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="$ns" xmlns:r="$_relNs"><dimension ref="A1"/><sheetViews><sheetView workbookViewId="0"/></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/><sheetData/><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>');
    _docs[part] = doc;
    _dirty.add(part);
    _addOverride('/$part', _sheetContentType);
    final rid = _addRelationship(_workbookPart, _sheetType, 'worksheets/sheet$n.xml');
    final sheets = _workbook.rootElement.kid('sheets')!;
    var sheetId = 1;
    for (final s in sheets.kids('sheet')) {
      final id = int.tryParse(s.attr('sheetId') ?? '') ?? 0;
      if (id >= sheetId) sheetId = id + 1;
    }
    final rPrefix = _prefixFor(_workbook.rootElement, _relNs) ?? 'r';
    if (_prefixFor(_workbook.rootElement, _relNs) == null) {
      _workbook.rootElement.setAttribute('xmlns:r', _relNs);
    }
    sheets.children.add(XmlElement(_name(sheets, 'sheet'), [
      XmlAttribute(XmlName.parts('name'), title),
      XmlAttribute(XmlName.parts('sheetId'), '$sheetId'),
      XmlAttribute(XmlName.parts('id', prefix: rPrefix), rid),
    ]));
    _dirty.add(_workbookPart);
    _indexSheets();
    _refresh();
    return _sheets.length - 1;
  }

  void renameSheet(int index, String name) {
    final title = name.trim();
    final problem = sheetNameProblem(title, except: index);
    if (problem != null) throw XlsxEditRefused(problem);
    final old = _sheets[index].name;
    if (old == title) return;
    _checkpoint();
    _sheets[index].element.setAttribute('name', title);
    _dirty.add(_workbookPart);
    // Point formulas, names and charts at the new name.
    final quoted = quoteSheetName(title);
    String rename(String f) => f.replaceAllMapped(
          RegExp("(?<![\\w.\\u00C0-\\uFFFF])('(?:[^']|'')+'|[A-Za-z_\\u00C0-\\uFFFF][\\w.\\u00C0-\\uFFFF]*)!"),
          (m) {
            final raw = m.group(1)!;
            final sheetName = raw.startsWith("'") ? raw.substring(1, raw.length - 1).replaceAll("''", "'") : raw;
            return sheetName.toLowerCase() == old.toLowerCase() ? '$quoted!' : m.group(0)!;
          },
        );
    for (final s in _sheets) {
      for (final f in s.doc.rootElement.deep('f')) {
        final next = rename(f.innerText);
        if (next != f.innerText) {
          f.innerText = next;
          _dirty.add(s.part);
        }
      }
    }
    for (final n in _workbook.rootElement.kid('definedNames')?.kids('definedName') ?? const <XmlElement>[]) {
      n.innerText = rename(n.innerText);
    }
    _mapChartFormulas(rename);
    _refresh();
  }

  String? _prefixFor(XmlElement el, String namespace) {
    for (final a in el.attributes) {
      if (a.name.prefix == 'xmlns' && a.value == namespace) return a.name.local;
    }
    return null;
  }

  String _addRelationship(String part, String type, String target) {
    final path = _relsPath(part);
    var doc = _doc(path);
    if (doc == null) {
      doc = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>');
      _docs[path] = doc;
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
    _dirty.add(path);
    return 'rId$i';
  }

  void _addOverride(String partName, String contentType) {
    final types = _doc('[Content_Types].xml')!;
    types.rootElement.children.add(XmlElement(XmlName.parts('Override'), [
      XmlAttribute(XmlName.parts('PartName'), partName),
      XmlAttribute(XmlName.parts('ContentType'), contentType),
    ]));
    _dirty.add('[Content_Types].xml');
  }

  // ---------------------------------------------------------------------------
  // After every content edit

  void _afterEdit(Set<String> touched) {
    _dirty.addAll(touched);
    _recalculate();
    for (final s in _sheets) {
      if (_dirty.contains(s.part)) _updateDimension(s);
    }
    _requestFullCalc();
    _styles = XlsxStyles.parse(_doc(_stylesPart));
    _refresh();
  }

  void _updateDimension(_Sheet sheet) {
    int? minR, maxR, minC, maxC;
    for (final c in sheet.doc.rootElement.kid('sheetData')?.deep('c') ?? const <XmlElement>[]) {
      final ref = XlsxReader.parseCellRef(c.attr('r') ?? '');
      if (ref == null) continue;
      minR = minR == null || ref.$1 < minR ? ref.$1 : minR;
      maxR = maxR == null || ref.$1 > maxR ? ref.$1 : maxR;
      minC = minC == null || ref.$2 < minC ? ref.$2 : minC;
      maxC = maxC == null || ref.$2 > maxC ? ref.$2 : maxC;
    }
    final value = minR == null
        ? 'A1'
        : '${XlsxReader.columnName(minC!)}${minR + 1}${minR == maxR && minC == maxC ? '' : ':${XlsxReader.columnName(maxC!)}${maxR! + 1}'}';
    var dim = sheet.doc.rootElement.kid('dimension');
    if (dim == null) {
      dim = _el(sheet.doc.rootElement, 'dimension');
      _insertSheetChild(sheet, dim);
    }
    dim.setAttribute('ref', value);
  }

  /// Asks Excel to recalculate every formula when the file is opened, and
  /// drops the calculation chain, which Excel rebuilds and which would be
  /// stale after edits.
  void _requestFullCalc() {
    final root = _workbook.rootElement;
    var calc = root.kid('calcPr');
    if (calc == null) {
      calc = _el(root, 'calcPr', {'calcId': '191029'});
      // calcPr comes after definedNames and before oleSize/customWorkbookViews/... extLst.
      const after = ['oleSize', 'customWorkbookViews', 'pivotCaches', 'smartTagPr', 'smartTagTypes', 'webPublishing', 'fileRecoveryPr', 'webPublishObjects', 'extLst'];
      final anchor = root.childElements.where((e) => after.contains(e.name.local)).firstOrNull;
      if (anchor == null) {
        root.children.add(calc);
      } else {
        root.children.insert(root.children.indexOf(anchor), calc);
      }
    }
    if (calc.attr('fullCalcOnLoad') != '1') {
      calc.setAttribute('fullCalcOnLoad', '1');
      _dirty.add(_workbookPart);
    }
    if (_archive.findFile('xl/calcChain.xml') != null && !_removed.contains('xl/calcChain.xml')) {
      _removed.add('xl/calcChain.xml');
      _docs.remove('xl/calcChain.xml');
      final rels = _doc(_relsPath(_workbookPart));
      rels?.rootElement.children.removeWhere((n) => n is XmlElement && (n.attr('Type') ?? '').endsWith('/calcChain'));
      _dirty.add(_relsPath(_workbookPart));
      final types = _doc('[Content_Types].xml')!;
      types.rootElement.children.removeWhere((n) => n is XmlElement && n.attr('PartName') == '/xl/calcChain.xml');
      _dirty.add('[Content_Types].xml');
    }
  }

  /// Works out formula results the app supports and stores them as each
  /// cell's cached value, so the sheet (and any app reading the file before
  /// Excel recalculates) shows current numbers.
  void _recalculate() {
    final byName = {for (var i = 0; i < _sheets.length; i++) _sheets[i].name.toLowerCase(): i};
    final cells = <int, Map<(int, int), XmlElement>>{};
    for (var i = 0; i < _sheets.length; i++) {
      final map = <(int, int), XmlElement>{};
      for (final c in _sheets[i].doc.rootElement.kid('sheetData')?.deep('c') ?? const <XmlElement>[]) {
        final ref = XlsxReader.parseCellRef(c.attr('r') ?? '');
        if (ref != null) map[ref] = c;
      }
      cells[i] = map;
    }
    final done = <(int, int, int), Object?>{};
    final busy = <(int, int, int)>{};

    Object? valueOf(int sheet, int r, int c) {
      final key = (sheet, r, c);
      if (done.containsKey(key)) return done[key];
      final cell = cells[sheet]![(r, c)];
      if (cell == null) return null;
      final f = cell.kid('f');
      if (f == null || f.attr('t') == 'array' || f.innerText.trim().isEmpty) return done[key] = _stored(cell);
      if (busy.contains(key)) throw const UnsupportedFormula('circular reference');
      busy.add(key);
      Object? result;
      try {
        result = FormulaEngine.evaluate(f.innerText, (name, rr, cc) {
          final target = name == null ? sheet : byName[name.toLowerCase()];
          if (target == null) throw UnsupportedFormula('sheet $name');
          return valueOf(target, rr, cc);
        });
        _storeResult(cell, result);
      } on UnsupportedFormula {
        result = _stored(cell);
      } finally {
        busy.remove(key);
      }
      return done[key] = result;
    }

    for (var i = 0; i < _sheets.length; i++) {
      for (final entry in cells[i]!.entries) {
        if (entry.value.kid('f') == null) continue;
        final before = entry.value.toXmlString();
        try {
          valueOf(i, entry.key.$1, entry.key.$2);
        } on UnsupportedFormula {
          // Circular: leave the stored value.
        }
        if (entry.value.toXmlString() != before) _dirty.add(_sheets[i].part);
      }
    }
  }

  Object? _stored(XmlElement cell) {
    final raw = cell.kid('v')?.innerText;
    switch (cell.attr('t')) {
      case 's':
        final i = int.tryParse(raw ?? '');
        return i != null && i < _shared.length ? _shared[i] : '';
      case 'inlineStr':
        return cell.deep('t').map((t) => t.innerText).join();
      case 'str':
        return raw ?? '';
      case 'b':
        return raw == '1';
      case 'e':
        return FormulaError(raw ?? '#VALUE!');
      default:
        return raw == null || raw.isEmpty ? null : double.tryParse(raw);
    }
  }

  void _storeResult(XmlElement cell, Object? result) {
    cell.removeAttribute('t');
    cell.children.removeWhere((n) => n is XmlElement && (n.name.local == 'v' || n.name.local == 'is'));
    String text;
    switch (result) {
      case double d:
        if (d.isNaN || d.isInfinite) {
          cell.setAttribute('t', 'e');
          text = '#NUM!';
        } else {
          text = _numberText(d);
        }
      case bool b:
        cell.setAttribute('t', 'b');
        text = b ? '1' : '0';
      case FormulaError e:
        cell.setAttribute('t', 'e');
        text = e.code;
      case null:
        text = '0';
      default:
        cell.setAttribute('t', 'str');
        text = result.toString();
    }
    final f = cell.kid('f')!;
    cell.children.insert(cell.children.indexOf(f) + 1, XmlElement(_name(cell, 'v'), [], [XmlText(text)]));
  }

  // ---------------------------------------------------------------------------
  // Saving

  /// The edited workbook. Untouched parts are copied unchanged.
  Uint8List save() {
    final out = Archive();
    final written = <String>{};
    for (final file in _archive.files) {
      if (!file.isFile || _removed.contains(file.name)) continue;
      final doc = _dirty.contains(file.name) ? _docs[file.name] : null;
      if (doc != null) {
        out.addFile(ArchiveFile.bytes(file.name, utf8.encode(_serialize(doc))));
      } else {
        out.addFile(ArchiveFile.bytes(file.name, file.content as List<int>));
      }
      written.add(file.name);
    }
    for (final path in _dirty) {
      if (written.contains(path) || _removed.contains(path)) continue;
      final doc = _docs[path];
      if (doc != null) out.addFile(ArchiveFile.bytes(path, utf8.encode(_serialize(doc))));
    }
    return Uint8List.fromList(ZipEncoder().encodeBytes(out));
  }

  /// Call after the bytes from [save] were written, so [hasChanges] resets.
  void markSaved() => _savedVersion = _version;

  static String _serialize(XmlDocument doc) {
    final text = doc.toXmlString();
    return text.startsWith('<?xml') ? text : '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n$text';
  }

  /// Escapes [text] for XML attribute or element content.
  static String escape(String text) => OoxmlPackageWriter.esc(text);
}

class _State {
  _State(this.docs, this.dirty, this.removed);

  final Map<String, String> docs;
  final Set<String> dirty;
  final Set<String> removed;
}
