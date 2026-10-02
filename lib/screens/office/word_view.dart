import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/ooxml/docx_reader.dart';
import '../../services/settings_store.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/reader_chrome.dart';

/// Office fonts first; Carlito and Liberation are metric-compatible stand-ins
/// where Calibri/Arial/Times are not installed.
const officeFontFallback = ['Calibri', 'Carlito', 'Arial', 'Liberation Sans', 'Helvetica'];

/// Reflowed Word document on a paper-like page.
class WordView extends StatefulWidget {
  const WordView({super.key, required this.document, required this.tone, required this.outlineRequests, required this.onStatus});

  final DocxDocument document;
  final PageTone tone;
  final ValueListenable<int> outlineRequests;
  final ValueChanged<String> onStatus;

  @override
  State<WordView> createState() => _WordViewState();
}

class _WordViewState extends State<WordView> {
  late List<GlobalKey> _keys;

  @override
  void initState() {
    super.initState();
    _keys = List.generate(widget.document.blocks.length, (_) => GlobalKey());
    widget.outlineRequests.addListener(_showOutline);
  }

  @override
  void dispose() {
    widget.outlineRequests.removeListener(_showOutline);
    super.dispose();
  }

  Future<void> _showOutline() async {
    final headings = <(int, DocxParagraph)>[];
    for (var i = 0; i < widget.document.blocks.length; i++) {
      final b = widget.document.blocks[i];
      if (b is DocxParagraph && (b.headingLevel > 0 || b.isTitle) && b.text.trim().isNotEmpty) headings.add((i, b));
    }
    final index = await showGlassSheet<int>(context, (sheet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Outline', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 10),
          if (headings.isEmpty) Text('This document has no headings.', style: TextStyle(color: sheet.palette.textMuted)),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.55),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (i, h) in headings)
                  ListTile(
                    contentPadding: EdgeInsets.only(left: 14.0 * (h.headingLevel > 0 ? h.headingLevel - 1 : 0)),
                    title: Text(h.text.trim(), style: TextStyle(fontWeight: h.headingLevel <= 1 ? FontWeight.w700 : FontWeight.w500)),
                    onTap: () => Navigator.pop(sheet, i),
                  ),
              ],
            ),
          ),
        ],
      );
    });
    final ctx = index == null ? null : _keys[index].currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.15);
    }
  }

  @override
  Widget build(BuildContext context) {
    final words = widget.document.plainText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    widget.onStatus('$words words · ${(words / 230).ceil()} min read');
    final filter = pageToneFilter(widget.tone);
    final page = Container(
      constraints: const BoxConstraints(maxWidth: 720),
      padding: const EdgeInsets.fromLTRB(26, 30, 26, 36),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFBFA),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 40, offset: const Offset(0, 18))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < widget.document.blocks.length; i++)
            KeyedSubtree(key: _keys[i], child: _block(widget.document.blocks[i])),
          if (widget.document.blocks.isEmpty) const Text('This document is empty.', style: TextStyle(color: Color(0xFF6B7280))),
        ],
      ),
    );
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(14, MediaQuery.paddingOf(context).top + 92, 14, 140),
      child: Center(child: filter == null ? page : ColorFiltered(colorFilter: filter, child: page)),
    );
  }

  Widget _block(DocxBlock block) => switch (block) {
        DocxParagraph p => _paragraph(p),
        DocxTable t => _table(t),
        DocxPageBreak _ => const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(color: Color(0xFFD9D9E0), thickness: 1),
          ),
        DocxImage img => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Image.memory(img.bytes, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ),
      };

  /// 11pt Word body text reads well at about 15 logical pixels on a phone.
  static const _ptToPx = 15 / 11;

  Widget _paragraph(DocxParagraph p) {
    final baseSize = p.isTitle
        ? 28.0
        : switch (p.headingLevel) {
            1 => 23.0,
            2 => 19.5,
            3 => 17.0,
            4 || 5 || 6 => 15.5,
            _ => 15.0,
          };
    final isHeading = p.isTitle || p.headingLevel > 0;
    final base = TextStyle(
      fontFamily: 'Calibri',
      fontFamilyFallback: officeFontFallback,
      fontSize: baseSize,
      height: isHeading ? 1.25 : 1.55,
      fontWeight: isHeading ? FontWeight.w700 : FontWeight.w400,
      color: isHeading && !p.isTitle ? const Color(0xFF1F3B73) : const Color(0xFF1C1C22),
    );
    if (p.runs.isEmpty) return const SizedBox(height: 10);
    final spans = [
      for (final r in p.runs)
        TextSpan(
          text: r.text,
          style: TextStyle(
            fontWeight: r.bold ? FontWeight.w700 : null,
            fontStyle: r.italic ? FontStyle.italic : null,
            decoration: TextDecoration.combine([
              if (r.underline) TextDecoration.underline,
              if (r.strike) TextDecoration.lineThrough,
            ]),
            fontSize: (!isHeading && r.fontSizePt != null) ? (r.fontSizePt! * _ptToPx).clamp(9.0, 40.0) : null,
            color: _hex(r.color),
            backgroundColor: _highlight(r.highlight),
          ),
        ),
    ];
    final align = switch (p.align) {
      ParagraphAlign.center => TextAlign.center,
      ParagraphAlign.right => TextAlign.right,
      ParagraphAlign.justify => TextAlign.justify,
      ParagraphAlign.left => TextAlign.left,
    };
    final text = Text.rich(TextSpan(style: base, children: spans), textAlign: align);
    final padding = EdgeInsets.only(top: isHeading ? 14 : 0, bottom: isHeading ? 6 : 8);
    if (p.listLevel == null) return Padding(padding: padding, child: text);
    return Padding(
      padding: padding.add(EdgeInsets.only(left: 18.0 * p.listLevel!)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 18, child: Text('•', style: base)),
          Expanded(child: text),
        ],
      ),
    );
  }

  Widget _table(DocxTable t) {
    if (t.rows.isEmpty) return const SizedBox.shrink();
    final cols = t.rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    const style = TextStyle(fontFamily: 'Calibri', fontFamilyFallback: officeFontFallback, fontSize: 13, color: Color(0xFF1C1C22), height: 1.35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: MediaQuery.sizeOf(context).width - 80),
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: const Color(0xFFD9D9E0), borderRadius: BorderRadius.circular(4)),
            children: [
              for (var r = 0; r < t.rows.length; r++)
                TableRow(
                  decoration: r == 0 ? const BoxDecoration(color: Color(0xFFEEF3FF)) : null,
                  children: [
                    for (var c = 0; c < cols; c++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(c < t.rows[r].length ? t.rows[r][c] : '', style: r == 0 ? style.copyWith(fontWeight: FontWeight.w700) : style),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Color? _hex(String? hex) {
    if (hex == null || hex.length != 6) return null;
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  static Color? _highlight(String? name) => switch (name) {
        'yellow' => const Color(0xFFFFF176),
        'green' => const Color(0xFFA5F3A1),
        'cyan' => const Color(0xFFA5F3FC),
        'magenta' => const Color(0xFFF5A3F0),
        'blue' => const Color(0xFF93C5FD),
        'red' => const Color(0xFFFCA5A5),
        'lightGray' => const Color(0xFFE5E7EB),
        _ => null,
      };
}
