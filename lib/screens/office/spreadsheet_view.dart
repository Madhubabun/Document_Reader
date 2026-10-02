import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ooxml/xlsx_editor.dart';
import '../../services/ooxml/xlsx_reader.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/pinch_zoom.dart';
import 'word_view.dart';

/// Grid view of an Excel workbook with sheet tabs and a formula bar.
///
/// With an [editor] the sheet is editable: tap a cell to select it, tap it
/// again (or the formula bar) to type, use the toolbar for bold, italic,
/// colours and alignment, and long-press a cell or a row or column header
/// for row, column and clipboard actions. Tap a sheet tab twice to rename it.
class SpreadsheetView extends StatefulWidget {
  const SpreadsheetView({super.key, required this.workbook, this.editor, required this.onStatus, this.onChanged});

  final XlsxWorkbook workbook;
  final XlsxEditor? editor;
  final ValueChanged<String> onStatus;

  /// Called after every edit, so the file can be saved.
  final VoidCallback? onChanged;

  /// Rendering caps keep huge sheets responsive on a phone.
  static const maxRows = 5000;
  static const maxCols = 100;

  /// Excel's sizes (64 px columns, 20 px rows, 11 pt text) scaled for a phone.
  static const scale = 1.2;

  @override
  State<SpreadsheetView> createState() => _SpreadsheetViewState();
}

/// A selected block of cells. Whole rows or columns come from tapping a header.
class _Selection {
  const _Selection(this.r1, this.c1, this.r2, this.c2, {this.wholeRow = false, this.wholeColumn = false});

  const _Selection.cell(int r, int c) : this(r, c, r, c);

  final int r1, c1, r2, c2;
  final bool wholeRow, wholeColumn;

  bool contains(int r, int c) => r >= r1 && r <= r2 && c >= c1 && c <= c2;
}

class _SpreadsheetViewState extends State<SpreadsheetView> {
  int _sheet = 0;
  _Selection? _sel;
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();

  static const _s = SpreadsheetView.scale;
  static const _rowHeight = 20 * _s;
  static const _headerWidth = 40 * _s;
  static const _headerHeight = 22 * _s;

  XlsxEditor? get _editor => widget.editor;
  List<XlsxSheet> get _sheets => _editor?.sheets ?? widget.workbook.sheets;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Column width in logical pixels from Excel's character units.
  double _colWidth(XlsxSheet sheet, int c) {
    final chars = sheet.columnWidths[c];
    if (chars == null) return 64 * _s;
    if (chars <= 0) return 0;
    return (chars * 7 + 5).roundToDouble() * _s;
  }

  // ---------------------------------------------------------------------------
  // Selection and typing

  void _select(_Selection sel) {
    if (_focus.hasFocus) _commit(move: false);
    setState(() => _sel = sel);
    _input.text = _editText(_sheets[_sheet].cell(sel.r1, sel.c1));
  }

  /// What the formula bar shows for editing: formulas with `=`, numbers
  /// unformatted, and text that would otherwise be read as a number or
  /// formula with a leading apostrophe, as in Excel.
  String _editText(XlsxCell? cell) {
    if (cell == null) return '';
    if (cell.formula != null) return '=${cell.formula}';
    if (cell.isNumber) return cell.style.isDate ? cell.value : cell.rawValue;
    final v = cell.value;
    final looksSpecial = v.startsWith('=') || v.startsWith("'") || RegExp(r'^\s*[+-]?[\d,]*\.?\d+\s*%?\s*$').hasMatch(v);
    return looksSpecial ? "'$v" : v;
  }

  void _startTyping() {
    if (_editor == null || _sel == null) return;
    _focus.requestFocus();
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _commit({bool move = true}) {
    final editor = _editor;
    final sel = _sel;
    if (editor == null || sel == null) return;
    final current = _editText(_sheets[_sheet].cell(sel.r1, sel.c1));
    if (_input.text != current) {
      _edit(() => editor.setCell(_sheet, sel.r1, sel.c1, _input.text));
    }
    if (move) {
      _focus.unfocus();
      _select(_Selection.cell(sel.r1 + 1, sel.c1));
    }
  }

  void _cancelTyping() {
    _focus.unfocus();
    final sel = _sel;
    if (sel != null) _input.text = _editText(_sheets[_sheet].cell(sel.r1, sel.c1));
  }

  /// Runs an edit, refreshes the grid and reports the change.
  void _edit(void Function() change) {
    try {
      change();
    } on XlsxEditRefused catch (e) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    setState(() {
      if (_sheet >= _sheets.length) _sheet = _sheets.length - 1;
    });
    final sel = _sel;
    if (sel != null && !_focus.hasFocus) _input.text = _editText(_sheets[_sheet].cell(sel.r1, sel.c1));
    widget.onChanged?.call();
  }

  /// Cells the toolbar acts on. Whole rows and columns cover the used area.
  List<(int, int)> _targets() {
    final sel = _sel;
    if (sel == null) return const [];
    final sheet = _sheets[_sheet];
    final c2 = sel.wholeRow ? (sheet.columnCount - 1).clamp(sel.c1, SpreadsheetView.maxCols) : sel.c2;
    final r2 = sel.wholeColumn ? (sheet.rowCount - 1).clamp(sel.r1, SpreadsheetView.maxRows) : sel.r2;
    return [
      for (var r = sel.r1; r <= r2; r++)
        for (var c = sel.c1; c <= c2; c++) (r, c),
    ];
  }

  XlsxCellStyle get _selStyle {
    final sel = _sel;
    return sel == null ? XlsxCellStyle.plain : (_sheets[_sheet].cell(sel.r1, sel.c1)?.style ?? XlsxCellStyle.plain);
  }

  // ---------------------------------------------------------------------------
  // Menus

  Future<void> _pickColor({required bool fill}) async {
    final editor = _editor;
    if (editor == null || _sel == null) return;
    final picked = await showGlassSheet<String>(
      context,
      (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fill ? 'Fill colour' : 'Text colour', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Swatch(color: null, label: fill ? 'No fill' : 'Automatic', onTap: () => Navigator.pop(context, '')),
              for (final rgb in _officeColors) _Swatch(color: Color(int.parse('FF$rgb', radix: 16)), label: rgb, onTap: () => Navigator.pop(context, rgb)),
            ],
          ),
        ],
      ),
    );
    if (picked == null) return;
    final targets = _targets();
    _edit(() => fill ? editor.setFill(_sheet, targets, picked.isEmpty ? null : picked) : editor.setFontColor(_sheet, targets, picked.isEmpty ? null : picked));
  }

  static const _officeColors = [
    'C00000', 'FF0000', 'FFC000', 'FFFF00', '92D050', '00B050', '00B0F0', '0070C0', '002060', '7030A0', //
    'FFFFFF', 'F2F2F2', 'D9D9D9', '808080', '404040', '000000', 'FCE4D6', 'E2EFDA', 'DDEBF7', 'FFF2CC',
  ];

  Future<void> _cellMenu(int r, int c) async {
    final editor = _editor;
    if (editor == null) return;
    if (_sel == null || !_sel!.contains(r, c)) _select(_Selection.cell(r, c));
    final sel = _sel!;
    final rows = sel.r2 - sel.r1 + 1;
    final cols = sel.c2 - sel.c1 + 1;
    final rowLabel = rows == 1 ? 'row' : '$rows rows';
    final colLabel = cols == 1 ? 'column' : '$cols columns';
    final cellText = _sheets[_sheet].cell(sel.r1, sel.c1)?.value ?? '';
    final action = await showGlassSheet<String>(
      context,
      (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!sel.wholeRow && !sel.wholeColumn) ...[
            _MenuItem(Icons.copy_rounded, 'Copy', () => Navigator.pop(context, 'copy')),
            _MenuItem(Icons.content_paste_rounded, 'Paste', () => Navigator.pop(context, 'paste')),
          ],
          _MenuItem(Icons.backspace_outlined, 'Clear contents', () => Navigator.pop(context, 'clear')),
          if (!sel.wholeColumn) ...[
            _MenuItem(Icons.vertical_align_top_rounded, 'Insert $rowLabel above', () => Navigator.pop(context, 'rowAbove')),
            _MenuItem(Icons.vertical_align_bottom_rounded, 'Insert $rowLabel below', () => Navigator.pop(context, 'rowBelow')),
            _MenuItem(Icons.delete_outline_rounded, 'Delete $rowLabel', () => Navigator.pop(context, 'rowDelete')),
          ],
          if (!sel.wholeRow) ...[
            _MenuItem(Icons.keyboard_tab_rounded, 'Insert $colLabel left', () => Navigator.pop(context, 'colLeft')),
            _MenuItem(Icons.keyboard_tab_rounded, 'Insert $colLabel right', () => Navigator.pop(context, 'colRight')),
            _MenuItem(Icons.delete_outline_rounded, 'Delete $colLabel', () => Navigator.pop(context, 'colDelete')),
          ],
        ],
      ),
    );
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: cellText));
      case 'paste':
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (text == null) return;
        // Tab- and line-separated text (as copied from Excel) fills a block.
        final lines = text.replaceAll('\r\n', '\n').split('\n');
        if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
        _edit(() {
          for (var i = 0; i < lines.length; i++) {
            final values = lines[i].split('\t');
            for (var j = 0; j < values.length; j++) {
              editor.setCell(_sheet, sel.r1 + i, sel.c1 + j, values[j]);
            }
          }
        });
      case 'clear':
        _edit(() => editor.clearCells(_sheet, _targets()));
      case 'rowAbove':
        _edit(() => editor.insertRows(_sheet, sel.r1, rows));
      case 'rowBelow':
        _edit(() => editor.insertRows(_sheet, sel.r2 + 1, rows));
      case 'rowDelete':
        _edit(() => editor.deleteRows(_sheet, sel.r1, rows));
      case 'colLeft':
        _edit(() => editor.insertColumns(_sheet, sel.c1, cols));
      case 'colRight':
        _edit(() => editor.insertColumns(_sheet, sel.c2 + 1, cols));
      case 'colDelete':
        _edit(() => editor.deleteColumns(_sheet, sel.c1, cols));
    }
  }

  Future<String?> _askName(String title, String initial, {int? except}) async {
    final editor = _editor;
    if (editor == null) return null;
    final controller = TextEditingController(text: initial);
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 31,
            decoration: InputDecoration(errorText: error),
            onChanged: (_) => setDialogState(() => error = null),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final problem = editor.sheetNameProblem(controller.text, except: except);
                if (problem != null) {
                  setDialogState(() => error = problem);
                } else {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _renameSheet(int index) async {
    final name = await _askName('Rename sheet', _sheets[index].name, except: index);
    if (name != null) _edit(() => _editor!.renameSheet(index, name));
  }

  void _addSheet() {
    late int index;
    _edit(() => index = _editor!.addSheet());
    if (index < _sheets.length) {
      setState(() {
        _sheet = index;
        _sel = null;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Building

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sheets = _sheets;
    if (sheets.isEmpty) {
      widget.onStatus('Empty workbook');
      return Center(child: Text('This workbook has no sheets.', style: TextStyle(color: p.textMuted)));
    }
    final sheet = sheets[_sheet];
    final rows = (sheet.rowCount + 20 < 40 ? 40 : sheet.rowCount + 20).clamp(0, SpreadsheetView.maxRows);
    final cols = (sheet.columnCount + 3 < 12 ? 12 : sheet.columnCount + 3).clamp(0, SpreadsheetView.maxCols);
    widget.onStatus('${sheets.length} ${sheets.length == 1 ? 'sheet' : 'sheets'} · ${sheet.cells.length} cells');
    final top = MediaQuery.paddingOf(context).top + 84;
    final widths = [for (var c = 0; c < cols; c++) _colWidth(sheet, c)];
    final totalWidth = widths.fold(_headerWidth, (a, b) => a + b);

    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: _formulaBar(p)),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 14),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: PinchZoom(
                minZoom: 0.4,
                maxZoom: 3,
                vertical: _vertical,
                horizontal: _horizontal,
                builder: (context, pinching) => Scrollbar(
                  controller: _horizontal,
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    physics: pinching ? const NeverScrollableScrollPhysics() : null,
                    child: SizedBox(
                      width: totalWidth,
                      child: Column(
                        children: [
                          _columnHeaders(widths),
                          Expanded(
                            child: ListView.builder(
                              controller: _vertical,
                              physics: pinching ? const NeverScrollableScrollPhysics() : null,
                              padding: const EdgeInsets.only(bottom: 120),
                              itemExtent: _rowHeight,
                              itemCount: rows,
                              itemBuilder: (context, r) => Row(
                                children: [
                                  _rowHeader(r),
                                  for (var c = 0; c < cols; c++)
                                    if (widths[c] > 0) _cell(sheet, r, c, widths[c]),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              children: [
                if (_editor != null && _sel != null && !_focus.hasFocus) ...[_toolbar(p), const SizedBox(height: 10)],
                SizedBox(height: 40, child: _sheetTabs(sheets)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _formulaBar(Palette p) {
    final sel = _sel;
    final editable = _editor != null && sel != null;
    final ref = sel == null
        ? '–'
        : sel.wholeRow
            ? '${sel.r1 + 1}${sel.r2 > sel.r1 ? ':${sel.r2 + 1}' : ''}'
            : sel.wholeColumn
                ? XlsxReader.columnName(sel.c1) + (sel.c2 > sel.c1 ? ':${XlsxReader.columnName(sel.c2)}' : '')
                : '${XlsxReader.columnName(sel.c1)}${sel.r1 + 1}';
    return GlassPanel(
      radius: 16,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Text(ref, style: TextStyle(fontWeight: FontWeight.w800, color: FileColors.excel.withValues(alpha: 0.95))),
            const SizedBox(width: 10),
            Text('fx', style: TextStyle(fontStyle: FontStyle.italic, color: p.textMuted, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: const ValueKey('formula-bar'),
                controller: _input,
                focusNode: _focus,
                readOnly: !editable,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontWeight: FontWeight.w600),
                decoration: InputDecoration.collapsed(hintText: editable ? 'Type a value or =formula' : ''),
                onSubmitted: (_) => _commit(),
              ),
            ),
            if (_focus.hasFocus) ...[
              IconButton(tooltip: 'Cancel', visualDensity: VisualDensity.compact, onPressed: _cancelTyping, icon: const Icon(Icons.close_rounded, size: 20)),
              IconButton(
                tooltip: 'Enter',
                visualDensity: VisualDensity.compact,
                onPressed: _commit,
                icon: const Icon(Icons.check_rounded, size: 20, color: Color(0xFF16A34A)),
              ),
            ] else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(Palette p) {
    final editor = _editor!;
    final style = _selStyle;
    Widget button(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GlassIconButton(icon: icon, tooltip: tip, onPressed: onTap, size: 40, color: on ? FileColors.excel : null),
        );
    final nextAlign = switch (style.align) { 'left' => 'center', 'center' => 'right', 'right' => null, _ => 'left' };
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          button(Icons.undo_rounded, 'Undo', editor.canUndo ? () => _edit(() => editor.undo()) : null),
          button(Icons.format_bold_rounded, 'Bold', () => _edit(() => editor.setBold(_sheet, _targets(), !style.bold)), on: style.bold),
          button(Icons.format_italic_rounded, 'Italic', () => _edit(() => editor.setItalic(_sheet, _targets(), !style.italic)), on: style.italic),
          button(Icons.format_color_fill_rounded, 'Fill colour', () => _pickColor(fill: true)),
          button(Icons.format_color_text_rounded, 'Text colour', () => _pickColor(fill: false)),
          button(
            switch (style.align) { 'center' => Icons.format_align_center_rounded, 'right' => Icons.format_align_right_rounded, _ => Icons.format_align_left_rounded },
            'Alignment',
            () => _edit(() => editor.setAlignment(_sheet, _targets(), nextAlign)),
            on: style.align != null,
          ),
          button(Icons.table_rows_outlined, 'Rows and columns', () => _cellMenu(_sel!.r1, _sel!.c1)),
          button(Icons.backspace_outlined, 'Clear', () => _edit(() => editor.clearCells(_sheet, _targets()))),
        ],
      ),
    );
  }

  Widget _sheetTabs(List<XlsxSheet> sheets) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: sheets.length + (_editor == null ? 0 : 1),
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, i) {
        if (i == sheets.length) {
          return GlassChip(label: '+ Sheet', selected: false, onTap: _addSheet);
        }
        return GlassChip(
          label: sheets[i].name,
          selected: i == _sheet,
          onTap: () {
            if (i == _sheet) {
              if (_editor != null) _renameSheet(i);
              return;
            }
            if (_focus.hasFocus) _commit(move: false);
            _focus.unfocus();
            setState(() {
              _sheet = i;
              _sel = null;
              _input.text = '';
            });
          },
        );
      },
    );
  }

  static const _headerColor = Color(0xFFF1F3F5);
  static const _gridColor = Color(0xFFE2E4E8);
  static const _selectColor = Color(0xFF16A34A);
  static const _headerStyle = TextStyle(fontSize: 11 * _s, fontWeight: FontWeight.w700, color: Color(0xFF55556A));

  Widget _columnHeaders(List<double> widths) {
    final sel = _sel;
    return Container(
      height: _headerHeight,
      color: _headerColor,
      child: Row(children: [
        const SizedBox(width: _headerWidth),
        for (var c = 0; c < widths.length; c++)
          if (widths[c] > 0)
            GestureDetector(
              onTap: () => _select(_Selection(0, c, 0, c, wholeColumn: true)),
              onLongPress: _editor == null
                  ? null
                  : () {
                      _select(_Selection(0, c, 0, c, wholeColumn: true));
                      _cellMenu(0, c);
                    },
              child: Container(
                width: widths[c],
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: sel != null && c >= sel.c1 && c <= sel.c2 ? _selectColor.withValues(alpha: 0.18) : null,
                  border: const Border(left: BorderSide(color: _gridColor)),
                ),
                child: Text(XlsxReader.columnName(c), style: _headerStyle),
              ),
            ),
      ]),
    );
  }

  Widget _rowHeader(int r) {
    final sel = _sel;
    return GestureDetector(
      onTap: () => _select(_Selection(r, 0, r, 0, wholeRow: true)),
      onLongPress: _editor == null
          ? null
          : () {
              _select(_Selection(r, 0, r, 0, wholeRow: true));
              _cellMenu(r, 0);
            },
      child: Container(
        width: _headerWidth,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel != null && r >= sel.r1 && r <= sel.r2 ? Color.alphaBlend(_selectColor.withValues(alpha: 0.18), _headerColor) : _headerColor,
          border: const Border(bottom: BorderSide(color: _gridColor)),
        ),
        child: Text('${r + 1}', style: _headerStyle),
      ),
    );
  }

  Widget _cell(XlsxSheet sheet, int r, int c, double width) {
    final cell = sheet.cell(r, c);
    final sel = _sel;
    final inSelection = sel != null && (sel.wholeRow ? r >= sel.r1 && r <= sel.r2 : sel.wholeColumn ? c >= sel.c1 && c <= sel.c2 : sel.contains(r, c));
    final active = sel != null && !sel.wholeRow && !sel.wholeColumn && sel.r1 == r && sel.c1 == c;
    final style = cell?.style ?? XlsxCellStyle.plain;
    final fill = style.fill == null ? null : Color(int.parse('FF${style.fill}', radix: 16));
    final color = style.fontColor == null ? const Color(0xFF1C1C22) : Color(int.parse('FF${style.fontColor}', radix: 16));
    final isBool = cell != null && !cell.isNumber && (cell.value == 'TRUE' || cell.value == 'FALSE') && cell.formula == null;
    final alignment = switch (style.align) {
      'center' || 'centerContinuous' => Alignment.center,
      'right' => Alignment.centerRight,
      'left' => Alignment.centerLeft,
      _ => cell?.isNumber == true ? Alignment.centerRight : (isBool ? Alignment.center : Alignment.centerLeft),
    };
    final pending = cell != null && cell.value.isEmpty && cell.formula != null;
    final text = TextStyle(
      fontFamily: 'Calibri',
      fontFamilyFallback: officeFontFallback,
      fontSize: 11 * 96 / 72 * _s * 0.86,
      color: pending ? const Color(0xFF6B7280) : color,
      fontWeight: style.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: style.italic || pending ? FontStyle.italic : FontStyle.normal,
      decoration: style.underline ? TextDecoration.underline : null,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (active) {
          _startTyping();
        } else {
          _select(_Selection.cell(r, c));
        }
      },
      onLongPress: _editor == null ? null : () => _cellMenu(r, c),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 3 * _s),
        alignment: alignment,
        decoration: BoxDecoration(
          color: inSelection && !active ? Color.alphaBlend(_selectColor.withValues(alpha: 0.14), fill ?? Colors.white) : fill,
          border: active
              ? Border.all(color: _selectColor, width: 2)
              : const Border(left: BorderSide(color: _gridColor), bottom: BorderSide(color: _gridColor)),
        ),
        child: cell == null
            ? null
            : Text(
                // Files saved by some tools carry a formula but no computed value yet.
                pending ? '=${cell.formula}' : cell.value,
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                style: text,
              ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.label, required this.onTap});

  final Color? color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color ?? Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: context.palette.glassBorder, width: 1.5),
          ),
          child: color == null ? const Icon(Icons.format_color_reset_rounded, size: 20, color: Color(0xFF6B7280)) : null,
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon, size: 22),
      title: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}
