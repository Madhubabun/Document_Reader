import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'docx_reader.dart';
import 'ooxml_editor.dart';
import 'xml_utils.dart';

/// Paragraph kinds the editor can switch between.
enum DocxParagraphKind { normal, title, heading1, heading2, heading3 }

/// Edits a .docx file in place.
///
/// Text changes are applied to the runs that hold the changed characters,
/// so the formatting of everything else (and every element the app doesn't
/// show, like fields, bookmarks, comments, footnotes and pictures) stays as
/// it was. Only `word/document.xml`, and `styles.xml` or `numbering.xml`
/// when a heading or bullet style has to be added, are rewritten.
class DocxEditor implements DocumentEditor {
  DocxEditor._(this._pkg);

  static const _main = 'word/document.xml';
  static const _wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

  final EditablePackage _pkg;
  late DocxDocument _document;
  final _paragraphs = <XmlElement>[];
  final _tables = <XmlElement>[];
  late Map<String, String> _styleNames;

  static DocxEditor open(List<int> bytes) {
    final editor = DocxEditor._(EditablePackage(bytes));
    if (editor._pkg.xml(_main) == null) throw OoxmlFormatException('Not a Word document (word/document.xml missing).');
    editor._reload();
    return editor;
  }

  DocxDocument get document => _document;

  @override
  bool get hasChanges => _pkg.hasChanges;

  @override
  bool get canUndo => _pkg.canUndo;

  @override
  bool undo() {
    final done = _pkg.undo();
    if (done) _reload();
    return done;
  }

  @override
  Uint8List save() => _pkg.save();

  @override
  void markSaved() => _pkg.markSaved();

  /// Starts an undo step. Typing in one paragraph calls this once, when the
  /// paragraph is first changed, rather than on every key.
  void checkpoint() => _pkg.checkpoint();

  XmlDocument get _doc => _pkg.xml(_main)!;
  String get _stylesPart => _pkg.relationshipOfType(_main, '/styles') ?? 'word/styles.xml';
  String get _numberingPart => _pkg.relationshipOfType(_main, '/numbering') ?? 'word/numbering.xml';

  void _reload() {
    _paragraphs.clear();
    _tables.clear();
    final styles = _pkg.xml(_stylesPart);
    _styleNames = DocxReader.styleNames(styles);
    _document = DocxReader.readParts(
      document: _doc,
      styles: styles,
      rels: _pkg.relationships(_main),
      bytes: _pkg.bytes,
      paragraphs: _paragraphs,
      tables: _tables,
    );
  }

  /// Re-reads one paragraph after a change that doesn't add or remove blocks.
  void _refresh(int ref) {
    final updated = DocxReader.readParagraph(_paragraphs[ref], _styleNames, ref: ref);
    final blocks = [
      for (final b in _document.blocks) b is DocxParagraph && b.ref == ref ? updated : b,
    ];
    _document = DocxDocument(blocks, page: _document.page);
  }

  void _structureChanged() {
    _pkg.touch(_main);
    _reload();
  }

  XmlElement _w(String local, [Map<String, String> attrs = const {}]) => XmlElement(
        XmlName.parts(local, prefix: _prefix),
        [for (final e in attrs.entries) XmlAttribute(XmlName.parts(e.key, prefix: _prefix), e.value)],
      );

  /// The prefix document.xml uses for WordprocessingML (almost always `w`).
  String? get _prefix => _doc.rootElement.name.prefix;

  // ---------------------------------------------------------------------------
  // Runs and text, read the same way as DocxReader

  /// Text runs of [container] in reading order.
  static List<XmlElement> _runs(XmlElement container) {
    final out = <XmlElement>[];
    void walk(XmlElement el) {
      for (final child in el.childElements) {
        switch (child.name.local) {
          case 'r':
            out.add(child);
          case 'hyperlink' || 'ins' || 'smartTag' || 'fldSimple':
            walk(child);
          case 'sdt':
            final content = child.kid('sdtContent');
            if (content != null) walk(content);
        }
      }
    }

    walk(container);
    return out;
  }

  static const _textParts = {'t', 'tab', 'br', 'cr', 'noBreakHyphen'};

  static String _runText(XmlElement r) {
    final buffer = StringBuffer();
    for (final child in r.childElements) {
      switch (child.name.local) {
        case 't':
          buffer.write(child.innerText);
        case 'tab':
          buffer.write('\t');
        case 'br' || 'cr':
          buffer.write('\n');
        case 'noBreakHyphen':
          buffer.write('-');
      }
    }
    return buffer.toString();
  }

  static String _text(XmlElement container) => _runs(container).map(_runText).join();

  /// Replaces the text of run [r], keeping its properties and any pictures
  /// or other content it holds.
  void _setRunText(XmlElement r, String text) {
    var at = -1;
    for (final child in r.childElements.toList()) {
      if (_textParts.contains(child.name.local)) {
        if (at < 0) at = r.children.indexOf(child);
        child.remove();
      }
    }
    if (at < 0) {
      final rPr = r.kid('rPr');
      at = rPr == null ? 0 : r.children.indexOf(rPr) + 1;
    }
    final nodes = <XmlElement>[];
    final pieces = RegExp(r'[^\t\n]+|\t|\n').allMatches(text).map((m) => m.group(0)!);
    for (final piece in pieces) {
      if (piece == '\t') {
        nodes.add(_w('tab'));
      } else if (piece == '\n') {
        nodes.add(_w('br'));
      } else {
        final t = _w('t')..innerText = piece;
        if (piece.trim() != piece) t.setAttribute('xml:space', 'preserve');
        nodes.add(t);
      }
    }
    r.children.insertAll(at, nodes);
  }

  static bool _hasOtherContent(XmlElement r) => r.childElements.any((c) => c.name.local != 'rPr' && !_textParts.contains(c.name.local));

  /// Replaces characters [start]..[end) of [p]'s text with [insert]. New
  /// text takes the formatting of the run it is typed into (the run before
  /// the cursor, like Word).
  void _replace(XmlElement p, int start, int end, String insert) {
    final runs = _runs(p);
    if (runs.isEmpty) {
      if (insert.isEmpty) return;
      final r = _w('r');
      // An empty paragraph's formatting lives on its paragraph mark.
      final markProps = p.kid('pPr')?.kid('rPr');
      if (markProps != null) {
        final rPr = markProps.copy();
        for (final name in const ['ins', 'del', 'moveFrom', 'moveTo', 'rPrChange']) {
          removeKids(rPr, name);
        }
        if (rPr.childElements.isNotEmpty) r.children.add(rPr);
      }
      p.children.add(r);
      _setRunText(r, insert);
      return;
    }
    final texts = runs.map(_runText).toList();
    // The run that receives the insertion.
    var target = 0;
    var pos = 0;
    for (var i = 0; i < runs.length; i++) {
      final len = texts[i].length;
      if (start > pos && start <= pos + len) {
        target = i;
        break;
      }
      if (start == 0 && len > 0) {
        target = i;
        break;
      }
      pos += len;
      target = i;
    }
    pos = 0;
    for (var i = 0; i < runs.length; i++) {
      final text = texts[i];
      final rs = pos;
      final re = pos + text.length;
      pos = re;
      final cutFrom = (start - rs).clamp(0, text.length);
      final cutTo = (end - rs).clamp(0, text.length);
      final keepsInsert = i == target && insert.isNotEmpty;
      if (cutFrom == cutTo && !keepsInsert) continue;
      var next = text.substring(0, cutFrom) + text.substring(cutTo);
      if (keepsInsert) {
        final at = (start - rs).clamp(0, next.length);
        next = next.substring(0, at) + insert + next.substring(at);
      }
      if (next.isEmpty && !_hasOtherContent(runs[i])) {
        runs[i].remove();
      } else {
        _setRunText(runs[i], next);
      }
    }
  }

  /// Splits runs so that [start]..[end) of [p] is covered by whole runs,
  /// and returns those runs.
  List<XmlElement> _isolate(XmlElement p, int start, int end) {
    for (final offset in [start, end]) {
      var pos = 0;
      for (final r in _runs(p)) {
        final text = _runText(r);
        if (offset > pos && offset < pos + text.length) {
          final right = r.copy();
          for (final child in right.childElements.toList()) {
            if (child.name.local != 'rPr' && !_textParts.contains(child.name.local)) child.remove();
          }
          _setRunText(right, text.substring(offset - pos));
          // Pictures and other content stay in the left half.
          _setRunText(r, text.substring(0, offset - pos));
          r.parent!.children.insert(r.parent!.children.indexOf(r) + 1, right);
          break;
        }
        pos += text.length;
      }
    }
    final out = <XmlElement>[];
    var pos = 0;
    for (final r in _runs(p)) {
      final len = _runText(r).length;
      if (pos >= start && pos + len <= end && len > 0) out.add(r);
      pos += len;
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Text edits

  /// Sets the text of a paragraph, changing only the runs that differ.
  void setParagraphText(int ref, String text) {
    final p = _paragraphs[ref];
    final old = _text(p);
    if (old == text) return;
    var prefix = 0;
    while (prefix < old.length && prefix < text.length && old.codeUnitAt(prefix) == text.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < old.length - prefix && suffix < text.length - prefix && old.codeUnitAt(old.length - 1 - suffix) == text.codeUnitAt(text.length - 1 - suffix)) {
      suffix++;
    }
    _replace(p, prefix, old.length - suffix, text.substring(prefix, text.length - suffix));
    _pkg.touch(_main);
    _pkg.changed();
    _refresh(ref);
  }

  /// Splits a paragraph at [offset] (the Enter key) and returns the new
  /// paragraph's ref. Everything after the cursor, including pictures,
  /// bookmarks and links, moves to the new paragraph.
  int splitParagraph(int ref, int offset) {
    _pkg.checkpoint();
    final p = _paragraphs[ref];
    final length = _text(p).length;
    final pPr = p.kid('pPr');
    final next = XmlElement(p.name, [
      // Word gives every paragraph its own id; leave the new one without.
      for (final a in p.attributes)
        if (a.name.local != 'paraId' && a.name.local != 'textId') a.copy(),
    ]);
    if (pPr != null) {
      final props = pPr.copy();
      // A section break belongs to the last paragraph of its section.
      final sectPr = pPr.kid('sectPr');
      if (sectPr != null) sectPr.remove();
      if (offset >= length) _applyNextStyle(props);
      next.children.add(props);
    }
    _moveAfter(p, offset, next, atEnd: offset >= length);
    p.parent!.children.insert(p.parent!.children.indexOf(p) + 1, next);
    _structureChanged();
    return ref + 1;
  }

  /// Moves the content of [from] at or after [offset] into [to].
  void _moveAfter(XmlElement from, int offset, XmlElement to, {bool atEnd = false}) {
    var pos = 0;
    for (final child in from.childElements.toList()) {
      final local = child.name.local;
      if (local == 'pPr') continue;
      final len = switch (local) {
        'r' => _runText(child).length,
        'hyperlink' || 'ins' || 'smartTag' || 'fldSimple' || 'sdt' => _text(child).length,
        _ => 0,
      };
      // Empty items at the split point (pictures, bookmarks) stay with the
      // text before them, unless the split is at the very start of text.
      if (pos > offset || (pos == offset && (len > 0 || (offset == 0 && !atEnd)))) {
        child.remove();
        to.children.add(child);
      } else if (pos + len > offset) {
        if (local == 'r') {
          final right = child.copy();
          for (final c in right.childElements.toList()) {
            if (c.name.local != 'rPr' && !_textParts.contains(c.name.local)) c.remove();
          }
          final text = _runText(child);
          _setRunText(child, text.substring(0, offset - pos));
          _setRunText(right, text.substring(offset - pos));
          to.children.add(right);
        } else if (local == 'sdt') {
          // Content controls carry ids; keep them whole on the left.
        } else {
          final right = XmlElement(child.name, [for (final a in child.attributes) a.copy()]);
          _moveAfter(child, offset - pos, right, atEnd: atEnd);
          to.children.add(right);
        }
      }
      pos += len;
    }
  }

  /// After Enter at the end of a heading, Word continues in the heading
  /// style's "next" style (normally Normal).
  void _applyNextStyle(XmlElement pPr) {
    final styleId = pPr.kid('pStyle')?.attr('val');
    if (styleId == null) return;
    final styles = _pkg.xml(_stylesPart);
    XmlElement? style;
    for (final s in styles?.rootElement.kids('style') ?? const <XmlElement>[]) {
      if (s.attr('styleId') == styleId) style = s;
    }
    final next = style?.kid('next')?.attr('val');
    final name = _styleNames[styleId] ?? '';
    if (next != null && next != styleId) {
      pPr.kid('pStyle')!.setAttribute(_prefix == null ? 'val' : '$_prefix:val', next);
    } else if (name.startsWith('heading') || name == 'title' || name == 'subtitle') {
      removeKids(pPr, 'pStyle');
    }
  }

  /// Joins a paragraph onto the one before it (Backspace at the start).
  /// Returns the cursor position in the joined paragraph, or null when the
  /// previous block is not a paragraph (a table, for example).
  int? joinWithPrevious(int ref) {
    final p = _paragraphs[ref];
    final previous = p.previousElementSibling;
    if (previous == null || previous.name.local != 'p') return null;
    _pkg.checkpoint();
    final cursor = _text(previous).length;
    for (final child in p.childElements.toList()) {
      if (child.name.local == 'pPr') continue;
      child.remove();
      previous.children.add(child);
    }
    final sectPr = p.kid('pPr')?.kid('sectPr');
    if (sectPr != null) {
      var props = previous.kid('pPr');
      if (props == null) {
        props = _w('pPr');
        previous.children.insert(0, props);
      }
      sectPr.remove();
      putInOrder(props, sectPr, _pPrOrder);
    }
    p.remove();
    _structureChanged();
    return cursor;
  }

  /// Removes a paragraph entirely. Returns false for the last paragraph of a
  /// table cell or of the document, which must keep one.
  bool deleteParagraph(int ref) {
    final p = _paragraphs[ref];
    final parent = p.parent;
    if (parent is! XmlElement || parent.kids('p').length < 2 || p.kid('pPr')?.kid('sectPr') != null) return false;
    _pkg.checkpoint();
    p.remove();
    _structureChanged();
    return true;
  }

  /// Sets a table cell's text; each line becomes a paragraph.
  void setCellText(int table, int row, int col, String text) {
    final tr = _tables[table].kids('tr').elementAtOrNull(row);
    final tc = tr?.kids('tc').elementAtOrNull(col);
    if (tc == null) return;
    _pkg.checkpoint();
    final lines = text.split('\n');
    var paragraphs = tc.kids('p').toList();
    if (paragraphs.isEmpty) {
      final p = _w('p');
      tc.children.add(p);
      paragraphs = [p];
    }
    for (var i = 0; i < lines.length; i++) {
      XmlElement p;
      if (i < paragraphs.length) {
        p = paragraphs[i];
      } else {
        final last = paragraphs.last;
        p = XmlElement(last.name, [for (final a in last.attributes) if (a.name.local != 'paraId' && a.name.local != 'textId') a.copy()]);
        final pPr = last.kid('pPr');
        if (pPr != null) p.children.add(pPr.copy());
        final lastRun = _runs(last).lastOrNull;
        final rPr = lastRun?.kid('rPr');
        if (rPr != null) {
          final r = _w('r')..children.add(rPr.copy());
          p.children.add(r);
        }
        final anchor = tc.kids('p').last;
        tc.children.insert(tc.children.indexOf(anchor) + 1, p);
      }
      final old = _text(p);
      _replace(p, 0, old.length, '');
      _replace(p, 0, 0, lines[i]);
    }
    for (final extra in paragraphs.skip(lines.length)) {
      extra.remove();
    }
    _structureChanged();
  }

  // ---------------------------------------------------------------------------
  // Character formatting

  static const _rPrOrder = [
    'rStyle', 'rFonts', 'b', 'bCs', 'i', 'iCs', 'caps', 'smallCaps', 'strike', 'dstrike', 'outline', 'shadow', 'emboss', //
    'imprint', 'noProof', 'snapToGrid', 'vanish', 'webHidden', 'color', 'spacing', 'w', 'kern', 'position', 'sz', 'szCs',
    'highlight', 'u', 'effect', 'bdr', 'shd', 'fitText', 'vertAlign', 'rtl', 'cs', 'em', 'lang', 'eastAsianLayout',
    'specVanish', 'oMath', 'rPrChange',
  ];

  /// Applies [change] to the run properties of characters [start]..[end) of
  /// a paragraph. With an empty range the whole paragraph changes.
  void _format(int ref, int start, int end, void Function(XmlElement rPr) change) {
    final p = _paragraphs[ref];
    final length = _text(p).length;
    if (start >= end) {
      start = 0;
      end = length;
    }
    _pkg.checkpoint();
    final runs = length == 0 ? <XmlElement>[] : _isolate(p, start, end);
    for (final r in runs) {
      var rPr = r.kid('rPr');
      if (rPr == null) {
        rPr = _w('rPr');
        r.children.insert(0, rPr);
      }
      change(rPr);
      if (rPr.childElements.isEmpty) rPr.remove();
    }
    // Formatting a whole paragraph also formats its mark, so text typed
    // into it later (or an empty paragraph) gets the same look.
    if (start == 0 && end >= length) {
      var pPr = p.kid('pPr');
      if (pPr == null) {
        pPr = _w('pPr');
        p.children.insert(0, pPr);
      }
      var markProps = pPr.kid('rPr');
      if (markProps == null) {
        markProps = _w('rPr');
        putInOrder(pPr, markProps, _pPrOrder);
      }
      change(markProps);
      if (markProps.childElements.isEmpty) markProps.remove();
    }
    _pkg.touch(_main);
    _refresh(ref);
  }

  void _toggle(XmlElement rPr, String name, bool on) => putInOrder(rPr, on ? _w(name) : _w(name, {'val': '0'}), _rPrOrder);

  void setBold(int ref, int start, int end, bool on) => _format(ref, start, end, (rPr) {
        _toggle(rPr, 'b', on);
        _toggle(rPr, 'bCs', on);
      });

  void setItalic(int ref, int start, int end, bool on) => _format(ref, start, end, (rPr) {
        _toggle(rPr, 'i', on);
        _toggle(rPr, 'iCs', on);
      });

  void setUnderline(int ref, int start, int end, bool on) =>
      _format(ref, start, end, (rPr) => putInOrder(rPr, _w('u', {'val': on ? 'single' : 'none'}), _rPrOrder));

  void setStrike(int ref, int start, int end, bool on) => _format(ref, start, end, (rPr) => _toggle(rPr, 'strike', on));

  /// Font size in points (Word stores half points).
  void setFontSize(int ref, int start, int end, double points) => _format(ref, start, end, (rPr) {
        final half = '${(points * 2).round().clamp(2, 3276)}';
        putInOrder(rPr, _w('sz', {'val': half}), _rPrOrder);
        putInOrder(rPr, _w('szCs', {'val': half}), _rPrOrder);
      });

  /// Text colour as RGB hex, or null for automatic.
  void setColor(int ref, int start, int end, String? rgb) =>
      _format(ref, start, end, (rPr) => rgb == null ? removeKids(rPr, 'color') : putInOrder(rPr, _w('color', {'val': rgb}), _rPrOrder));

  /// Word's highlight colours: yellow, green, cyan, magenta, blue, red,
  /// darkBlue, darkCyan, darkGreen, darkMagenta, darkRed, darkYellow,
  /// darkGray, lightGray, black. Null removes the highlight.
  void setHighlight(int ref, int start, int end, String? color) =>
      _format(ref, start, end, (rPr) => color == null ? removeKids(rPr, 'highlight') : putInOrder(rPr, _w('highlight', {'val': color}), _rPrOrder));

  /// Sets the font for Latin and complex-script text, e.g. Calibri, Arial or
  /// Times New Roman.
  void setFont(int ref, int start, int end, String font) => _format(ref, start, end, (rPr) {
        putInOrder(rPr, _w('rFonts', {'ascii': font, 'hAnsi': font, 'cs': font}), _rPrOrder);
      });

  // ---------------------------------------------------------------------------
  // Paragraph formatting

  static const _pPrOrder = [
    'pStyle', 'keepNext', 'keepLines', 'pageBreakBefore', 'framePr', 'widowControl', 'numPr', 'suppressLineNumbers', //
    'pBdr', 'shd', 'tabs', 'suppressAutoHyphens', 'kinsoku', 'wordWrap', 'overflowPunct', 'topLinePunct', 'autoSpaceDE',
    'autoSpaceDN', 'bidi', 'adjustRightInd', 'snapToGrid', 'spacing', 'ind', 'contextualSpacing', 'mirrorIndents',
    'suppressOverlap', 'jc', 'textDirection', 'textAlignment', 'textboxTightWrap', 'outlineLvl', 'divId', 'cnfStyle',
    'rPr', 'sectPr', 'pPrChange',
  ];

  XmlElement _pPr(XmlElement p) {
    var pPr = p.kid('pPr');
    if (pPr == null) {
      pPr = _w('pPr');
      p.children.insert(0, pPr);
    }
    return pPr;
  }

  void _paragraphChange(int ref, void Function(XmlElement pPr) change) {
    _pkg.checkpoint();
    final p = _paragraphs[ref];
    final pPr = _pPr(p);
    change(pPr);
    if (pPr.childElements.isEmpty && pPr.attributes.isEmpty) pPr.remove();
    _pkg.touch(_main);
    _refresh(ref);
  }

  void setAlignment(int ref, ParagraphAlign align) => _paragraphChange(ref, (pPr) {
        if (align == ParagraphAlign.left) {
          removeKids(pPr, 'jc');
        } else {
          final value = switch (align) { ParagraphAlign.center => 'center', ParagraphAlign.right => 'right', _ => 'both' };
          putInOrder(pPr, _w('jc', {'val': value}), _pPrOrder);
        }
      });

  /// Makes a paragraph body text, the title or a heading, using the
  /// document's own styles (and adding Word's standard ones if missing).
  void setParagraphKind(int ref, DocxParagraphKind kind) {
    final styleId = kind == DocxParagraphKind.normal ? null : _ensureStyle(kind);
    _paragraphChange(ref, (pPr) {
      removeKids(pPr, 'outlineLvl');
      if (styleId == null) {
        removeKids(pPr, 'pStyle');
      } else {
        putInOrder(pPr, _w('pStyle', {'val': styleId}), _pPrOrder);
      }
    });
  }

  String _ensureStyle(DocxParagraphKind kind) {
    final name = switch (kind) {
      DocxParagraphKind.title => 'title',
      DocxParagraphKind.heading1 => 'heading 1',
      DocxParagraphKind.heading2 => 'heading 2',
      _ => 'heading 3',
    };
    for (final e in _styleNames.entries) {
      if (e.value == name) return e.key;
    }
    var styles = _pkg.xml(_stylesPart);
    if (styles == null) {
      // Word's defaults: Calibri 11 pt body text in a Normal style.
      styles = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="$_wNs">'
          '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Times New Roman"/>'
          '<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>'
          '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
          '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style></w:styles>');
      _styleNames['Normal'] = 'normal';
      _pkg.put('word/styles.xml', styles);
      _pkg.addRelationship(_main, '${EditablePackage.relNs}/styles', 'styles.xml');
      _pkg.addOverride('/word/styles.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml');
    }
    // Word's built-in definitions (Office 2013+ theme look), in standard fonts.
    final (id, size, color, outline) = switch (kind) {
      DocxParagraphKind.title => ('Title', 56, null, null),
      DocxParagraphKind.heading1 => ('Heading1', 32, '2F5496', 0),
      DocxParagraphKind.heading2 => ('Heading2', 26, '2F5496', 1),
      _ => ('Heading3', 24, '1F3763', 2),
    };
    final w = styles.rootElement.name.prefix ?? 'w';
    final fragment = XmlDocumentFragment.parse(
      '<$w:style xmlns:$w="$_wNs" $w:type="paragraph" $w:styleId="$id"><$w:name $w:val="${name == 'title' ? 'Title' : name}"/>'
      '<$w:basedOn $w:val="Normal"/><$w:next $w:val="Normal"/><$w:uiPriority $w:val="${kind == DocxParagraphKind.title ? 10 : 9}"/><$w:qFormat/>'
      '<$w:pPr>${outline == null ? '' : '<$w:keepNext/><$w:keepLines/><$w:spacing $w:before="${outline == 0 ? 240 : 40}" $w:after="0"/><$w:outlineLvl $w:val="$outline"/>'}'
      '${outline == null ? '<$w:contextualSpacing/>' : ''}</$w:pPr>'
      '<$w:rPr><$w:rFonts $w:ascii="Calibri Light" $w:hAnsi="Calibri Light" $w:cs="Times New Roman"/>'
      '${color == null ? '' : '<$w:color $w:val="$color"/>'}<$w:sz $w:val="$size"/><$w:szCs $w:val="$size"/></$w:rPr></$w:style>',
    );
    final style = fragment.firstElementChild!.copy();
    style.removeAttribute('xmlns:$w');
    styles.rootElement.children.add(style);
    _pkg.touch(_stylesPart);
    _styleNames[id] = name;
    return id;
  }

  /// Turns bullets on or off for a paragraph.
  void toggleBullets(int ref) {
    final pPr = _paragraphs[ref].kid('pPr');
    final style = pPr?.kid('pStyle')?.attr('val');
    final isList = pPr?.kid('numPr') != null || (style != null && (_styleNames[style] ?? '').startsWith('list'));
    final numId = isList ? null : _bulletNumId();
    _paragraphChange(ref, (pPr) {
      if (numId == null) {
        removeKids(pPr, 'numPr');
        // Paragraphs in a list style still look like list items; make it plain.
        final style = pPr.kid('pStyle')?.attr('val');
        if (style != null && (_styleNames[style] ?? '').startsWith('list')) removeKids(pPr, 'pStyle');
      } else {
        final numPr = _w('numPr')
          ..children.addAll([
            _w('ilvl', {'val': '0'}),
            _w('numId', {'val': numId}),
          ]);
        putInOrder(pPr, numPr, _pPrOrder);
      }
    });
  }

  /// A numbering instance whose first level is a bullet, adding one (and
  /// the numbering part) when the document has none.
  String _bulletNumId() {
    var numbering = _pkg.xml(_numberingPart);
    if (numbering != null) {
      final bulletAbstracts = <String>{
        for (final a in numbering.rootElement.kids('abstractNum'))
          if (a.kids('lvl').firstOrNull?.kid('numFmt')?.attr('val') == 'bullet' && a.attr('abstractNumId') != null) a.attr('abstractNumId')!,
      };
      for (final num in numbering.rootElement.kids('num')) {
        if (bulletAbstracts.contains(num.kid('abstractNumId')?.attr('val')) && num.attr('numId') != null) return num.attr('numId')!;
      }
    } else {
      numbering = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="$_wNs"/>');
      _pkg.put('word/numbering.xml', numbering);
      _pkg.addRelationship(_main, '${EditablePackage.relNs}/numbering', 'numbering.xml');
      _pkg.addOverride('/word/numbering.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml');
    }
    final root = numbering.rootElement;
    final w = root.name.prefix ?? 'w';
    int nextId(String element, String attr) =>
        root.kids(element).map((e) => int.tryParse(e.attr(attr) ?? '') ?? 0).fold(0, (a, b) => a > b ? a : b) + 1;
    final abstractId = nextId('abstractNum', 'abstractNumId');
    final numId = nextId('num', 'numId');
    const glyphs = ['•', 'o', '▪'];
    final levels = StringBuffer();
    for (var i = 0; i < 9; i++) {
      final glyph = glyphs[i % 3];
      final font = glyph == 'o' ? 'Courier New' : (glyph == '•' ? 'Symbol' : 'Wingdings');
      final text = glyph == '•' ? '' : (glyph == 'o' ? 'o' : '');
      levels.write('<$w:lvl $w:ilvl="$i"><$w:start $w:val="1"/><$w:numFmt $w:val="bullet"/><$w:lvlText $w:val="$text"/><$w:lvlJc $w:val="left"/>'
          '<$w:pPr><$w:ind $w:left="${720 * (i + 1)}" $w:hanging="360"/></$w:pPr>'
          '<$w:rPr><$w:rFonts $w:ascii="$font" $w:hAnsi="$font" $w:hint="default"/></$w:rPr></$w:lvl>');
    }
    final abstractNum = XmlDocumentFragment.parse(
      '<$w:abstractNum xmlns:$w="$_wNs" $w:abstractNumId="$abstractId"><$w:multiLevelType $w:val="hybridMultilevel"/>$levels</$w:abstractNum>',
    ).firstElementChild!.copy()
      ..removeAttribute('xmlns:$w');
    final num = XmlDocumentFragment.parse('<$w:num xmlns:$w="$_wNs" $w:numId="$numId"><$w:abstractNumId $w:val="$abstractId"/></$w:num>')
        .firstElementChild!
        .copy()
      ..removeAttribute('xmlns:$w');
    // All abstractNum elements come before the first num.
    final firstNum = root.kids('num').firstOrNull;
    if (firstNum == null) {
      root.children.add(abstractNum);
    } else {
      root.children.insert(root.children.indexOf(firstNum), abstractNum);
    }
    final after = root.kids('num').lastOrNull;
    if (after == null) {
      root.children.add(num);
    } else {
      root.children.insert(root.children.indexOf(after) + 1, num);
    }
    _pkg.touch(_numberingPart);
    return '$numId';
  }

  /// Inserts an empty paragraph after [ref] (after a table, use the
  /// paragraph that follows it) and returns its ref.
  int insertParagraphAfter(int ref) => splitParagraph(ref, _text(_paragraphs[ref]).length);
}
