import 'package:flutter/material.dart';

import '../../services/ooxml/xlsx_reader.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import 'word_view.dart';

/// Grid view of an Excel workbook with sheet tabs and a formula bar.
class SpreadsheetView extends StatefulWidget {
  const SpreadsheetView({super.key, required this.workbook, required this.onStatus});

  final XlsxWorkbook workbook;
  final ValueChanged<String> onStatus;

  /// Rendering caps keep huge sheets responsive on a phone.
  static const maxRows = 5000;
  static const maxCols = 100;

  @override
  State<SpreadsheetView> createState() => _SpreadsheetViewState();
}

class _SpreadsheetViewState extends State<SpreadsheetView> {
  int _sheet = 0;
  (int, int)? _selected;
  final _horizontal = ScrollController();

  static const _colWidth = 112.0;
  static const _rowHeight = 36.0;
  static const _headerWidth = 44.0;

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sheets = widget.workbook.sheets;
    if (sheets.isEmpty) {
      widget.onStatus('Empty workbook');
      return Center(child: Text('This workbook has no sheets.', style: TextStyle(color: p.textMuted)));
    }
    final sheet = sheets[_sheet];
    final rows = (sheet.rowCount < 30 ? 30 : sheet.rowCount).clamp(0, SpreadsheetView.maxRows);
    final cols = (sheet.columnCount < 8 ? 8 : sheet.columnCount).clamp(0, SpreadsheetView.maxCols);
    widget.onStatus('${sheets.length} ${sheets.length == 1 ? 'sheet' : 'sheets'} · ${sheet.cells.length} cells');
    final sel = _selected;
    final selCell = sel == null ? null : sheet.cell(sel.$1, sel.$2);
    final top = MediaQuery.paddingOf(context).top + 84;

    const cellStyle = TextStyle(fontFamily: 'Calibri', fontFamilyFallback: officeFontFallback, fontSize: 13.5, color: Color(0xFF1C1C22));
    final headerStyle = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: const Color(0xFF55556A));

    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: GlassPanel(
              radius: 16,
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Text(sel == null ? '–' : '${XlsxReader.columnName(sel.$2)}${sel.$1 + 1}',
                        style: TextStyle(fontWeight: FontWeight.w800, color: FileColors.excel.withValues(alpha: 0.95))),
                    const SizedBox(width: 10),
                    Text('fx', style: TextStyle(fontStyle: FontStyle.italic, color: p.textMuted, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        selCell == null ? '' : (selCell.formula != null ? '=${selCell.formula}' : selCell.value),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 14),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: Scrollbar(
                controller: _horizontal,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: _headerWidth + cols * _colWidth,
                    child: Column(
                      children: [
                        Container(
                          height: 30,
                          color: const Color(0xFFF1F3F5),
                          child: Row(children: [
                            const SizedBox(width: _headerWidth),
                            for (var c = 0; c < cols; c++)
                              Container(
                                width: _colWidth,
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFFE2E4E8)))),
                                child: Text(XlsxReader.columnName(c), style: headerStyle),
                              ),
                          ]),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.only(bottom: 120),
                            itemExtent: _rowHeight,
                            itemCount: rows,
                            itemBuilder: (context, r) => Row(
                              children: [
                                Container(
                                  width: _headerWidth,
                                  alignment: Alignment.center,
                                  color: const Color(0xFFF1F3F5),
                                  child: Text('${r + 1}', style: headerStyle),
                                ),
                                for (var c = 0; c < cols; c++) _cell(sheet, r, c, cellStyle),
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
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: sheets.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => GlassChip(
                  label: sheets[i].name,
                  selected: i == _sheet,
                  onTap: () => setState(() {
                    _sheet = i;
                    _selected = null;
                  }),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(XlsxSheet sheet, int r, int c, TextStyle style) {
    final cell = sheet.cell(r, c);
    final selected = _selected == (r, c);
    return GestureDetector(
      onTap: () => setState(() => _selected = (r, c)),
      child: Container(
        width: _colWidth,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: cell?.isNumber == true ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: selected ? FileColors.excel.withValues(alpha: 0.12) : null,
          border: selected
              ? Border.all(color: const Color(0xFF16A34A), width: 2)
              : const Border(left: BorderSide(color: Color(0xFFE2E4E8)), bottom: BorderSide(color: Color(0xFFE2E4E8))),
        ),
        child: cell == null
            ? null
            : Text(
                // Files saved by some tools carry a formula but no computed value yet.
                cell.value.isEmpty && cell.formula != null ? '=${cell.formula}' : cell.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: cell.value.isEmpty ? style.copyWith(color: const Color(0xFF6B7280), fontStyle: FontStyle.italic) : style,
              ),
      ),
    );
  }
}
