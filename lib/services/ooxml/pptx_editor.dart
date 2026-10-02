import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'ooxml_editor.dart';
import 'pptx_reader.dart';
import 'xml_utils.dart';

/// Edits a .pptx file in place: shape text and formatting, shape position
/// and size, text boxes, and adding, duplicating, deleting and reordering
/// slides. Only the slides and package parts an edit touches are
/// rewritten; masters, layouts, themes, media, notes and anything else are
/// copied byte for byte.
class PptxEditor implements DocumentEditor {
  PptxEditor._(this._pkg);

  static const _presPart = 'ppt/presentation.xml';
  static const _aNs = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  static const _pNs = 'http://schemas.openxmlformats.org/presentationml/2006/main';
  static const _slideType = '${EditablePackage.relNs}/slide';
  static const _slideContentType = 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml';

  final EditablePackage _pkg;
  late PptxPresentation _presentation;
  final _slideParts = <String>[];
  final _shapes = <List<XmlElement>>[];

  static PptxEditor open(List<int> bytes) {
    final editor = PptxEditor._(EditablePackage(bytes));
    if (editor._pkg.xml(_presPart) == null) throw OoxmlFormatException('Not a PowerPoint file (ppt/presentation.xml missing).');
    editor._reload();
    return editor;
  }

  PptxPresentation get presentation => _presentation;

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

  XmlDocument get _pres => _pkg.xml(_presPart)!;

  void _reload() {
    _slideParts.clear();
    _shapes.clear();
    _presentation = PptxReader.readFrom(_pkg, slideParts: _slideParts, shapeElements: _shapes);
  }

  /// Re-reads one slide after an edit that only changed that slide.
  void _refresh(int slide) {
    final part = _slideParts[slide];
    _pkg.touch(part);
    final elements = <XmlElement>[];
    final updated = PptxReader.readSlide(_pkg, part, _pkg.xml(part)!, _pres.rootElement.kid('defaultTextStyle'), elements: elements);
    _shapes[slide] = elements;
    _presentation = PptxPresentation(
      slideWidth: _presentation.slideWidth,
      slideHeight: _presentation.slideHeight,
      slides: [for (var i = 0; i < _presentation.slides.length; i++) i == slide ? updated : _presentation.slides[i]],
    );
  }

  XmlElement _shape(int slide, int ref) => _shapes[slide][ref];

  XmlElement _a(String local, [Map<String, String> attrs = const {}]) =>
      XmlElement(XmlName.parts(local, prefix: 'a'), [for (final e in attrs.entries) XmlAttribute(XmlName.parts(e.key), e.value)]);

  /// Makes sure the `a` prefix means DrawingML in [doc] (it always does in
  /// files from PowerPoint; declare it otherwise).
  void _declareA(XmlDocument doc) {
    final root = doc.rootElement;
    if (!root.attributes.any((a) => a.name.prefix == 'xmlns' && a.name.local == 'a')) root.setAttribute('xmlns:a', _aNs);
  }

  // ---------------------------------------------------------------------------
  // Text

  static String _paragraphText(XmlElement p) {
    final buffer = StringBuffer();
    for (final child in p.childElements) {
      switch (child.name.local) {
        case 'r' || 'fld':
          buffer.write(child.kid('t')?.innerText ?? '');
        case 'br':
          buffer.write('\n');
      }
    }
    return buffer.toString();
  }

  /// Text runs of a paragraph; line breaks count as one character.
  static List<XmlElement> _runs(XmlElement p) =>
      p.childElements.where((c) => c.name.local == 'r' || c.name.local == 'fld' || c.name.local == 'br').toList();

  static String _runText(XmlElement r) => r.name.local == 'br' ? '\n' : (r.kid('t')?.innerText ?? '');

  void _setRunText(XmlElement r, String text) {
    var t = r.kid('t');
    if (t == null) {
      t = _a('t');
      r.children.add(t);
    }
    t.innerText = text;
  }

  /// Replaces characters [start]..[end) of paragraph [p] with [insert],
  /// keeping the formatting of the runs around the change.
  void _replace(XmlElement p, int start, int end, String insert) {
    final runs = _runs(p);
    final texts = runs.map(_runText).toList();
    if (runs.where((r) => r.name.local != 'br').isEmpty) {
      // Only line breaks (or nothing): rebuild the paragraph's text.
      final mark = p.kid('endParaRPr');
      final full = texts.join();
      final next = full.substring(0, start) + insert + full.substring(end);
      for (final r in runs) {
        r.remove();
      }
      final rPr = mark == null ? _a('rPr', {'lang': 'en-US', 'dirty': '0'}) : _renamed(mark.copy(), 'rPr');
      final pieces = RegExp(r'[^\n]+|\n').allMatches(next).map((m) => m.group(0)!);
      final nodes = <XmlElement>[
        for (final piece in pieces)
          piece == '\n' ? (_a('br')..children.add(rPr.copy())) : (_a('r')..children.addAll([rPr.copy(), _a('t')..innerText = piece])),
      ];
      if (mark == null) {
        p.children.addAll(nodes);
      } else {
        p.children.insertAll(p.children.indexOf(mark), nodes);
      }
      return;
    }
    var target = -1;
    var pos = 0;
    for (var i = 0; i < runs.length; i++) {
      final len = texts[i].length;
      if (runs[i].name.local != 'br' && ((start > pos && start <= pos + len) || (start == pos && target < 0))) {
        target = i;
        if (start > pos) break;
      }
      pos += len;
    }
    if (target < 0) target = runs.lastIndexWhere((r) => r.name.local != 'br');
    pos = 0;
    for (var i = 0; i < runs.length; i++) {
      final text = texts[i];
      final rs = pos;
      pos += text.length;
      final cutFrom = (start - rs).clamp(0, text.length);
      final cutTo = (end - rs).clamp(0, text.length);
      final keepsInsert = i == target && insert.isNotEmpty;
      if (cutFrom == cutTo && !keepsInsert) continue;
      if (runs[i].name.local == 'br') {
        runs[i].remove();
        continue;
      }
      var next = text.substring(0, cutFrom) + text.substring(cutTo);
      if (keepsInsert) {
        final at = (start - rs).clamp(0, next.length);
        next = next.substring(0, at) + insert + next.substring(at);
      }
      if (next.isEmpty) {
        // Keep the formatting on the paragraph mark when the last run goes.
        final rPr = runs[i].kid('rPr');
        if (rPr != null && p.kid('endParaRPr') == null) p.children.add(_renamed(rPr.copy(), 'endParaRPr'));
        runs[i].remove();
      } else {
        _setRunText(runs[i], next);
      }
    }
  }

  static XmlElement _renamed(XmlElement el, String local) {
    if (el.name.local == local) return el;
    return XmlElement(XmlName.parts(local, prefix: el.name.prefix), [for (final a in el.attributes) a.copy()], [for (final c in el.children) c.copy()]);
  }

  /// Sets the text of a shape. Each line is a paragraph; paragraphs whose
  /// text is unchanged are left exactly as they were.
  void setShapeText(int slide, int ref, String text) {
    final sp = _shape(slide, ref);
    if (sp.name.local != 'sp') return;
    _pkg.checkpoint();
    var txBody = sp.kid('txBody');
    if (txBody == null) {
      txBody = XmlElement(XmlName.parts('txBody', prefix: sp.name.prefix), [], [_a('bodyPr'), _a('lstStyle'), _a('p')]);
      sp.children.add(txBody);
    }
    var paragraphs = txBody.kids('p').toList();
    if (paragraphs.isEmpty) {
      final p = _a('p');
      txBody.children.add(p);
      paragraphs = [p];
    }
    final old = paragraphs.map(_paragraphText).toList();
    final lines = text.split('\n');
    var prefix = 0;
    while (prefix < old.length && prefix < lines.length && old[prefix] == lines[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < old.length - prefix && suffix < lines.length - prefix && old[old.length - 1 - suffix] == lines[lines.length - 1 - suffix]) {
      suffix++;
    }
    final oldMiddle = paragraphs.sublist(prefix, paragraphs.length - suffix);
    final newMiddle = lines.sublist(prefix, lines.length - suffix);
    // Reuse paragraphs in order, then add copies of the last one or remove extras.
    final template = oldMiddle.isNotEmpty ? oldMiddle.last : paragraphs[prefix == 0 ? 0 : prefix - 1];
    XmlElement anchor = prefix == 0 ? paragraphs.first : paragraphs[prefix - 1];
    var insertBefore = prefix == 0;
    for (var i = 0; i < newMiddle.length; i++) {
      XmlElement p;
      if (i < oldMiddle.length) {
        p = oldMiddle[i];
      } else {
        p = _blankLike(template);
        if (insertBefore) {
          txBody.children.insert(txBody.children.indexOf(anchor), p);
        } else {
          txBody.children.insert(txBody.children.indexOf(anchor) + 1, p);
        }
      }
      anchor = p;
      insertBefore = false;
      final current = _paragraphText(p);
      if (current != newMiddle[i]) _setParagraph(p, current, newMiddle[i]);
    }
    for (final extra in oldMiddle.skip(newMiddle.length)) {
      extra.remove();
    }
    if (txBody.kids('p').isEmpty) txBody.children.add(_a('p'));
    _refresh(slide);
  }

  void _setParagraph(XmlElement p, String old, String text) {
    var prefix = 0;
    while (prefix < old.length && prefix < text.length && old.codeUnitAt(prefix) == text.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < old.length - prefix && suffix < text.length - prefix && old.codeUnitAt(old.length - 1 - suffix) == text.codeUnitAt(text.length - 1 - suffix)) {
      suffix++;
    }
    _replace(p, prefix, old.length - suffix, text.substring(prefix, text.length - suffix));
  }

  /// An empty paragraph with [like]'s paragraph and character formatting.
  XmlElement _blankLike(XmlElement like) {
    final p = XmlElement(like.name);
    final pPr = like.kid('pPr');
    if (pPr != null) p.children.add(pPr.copy());
    final lastRun = like.childElements.where((c) => c.name.local == 'r').lastOrNull;
    final end = like.kid('endParaRPr') ?? lastRun?.kid('rPr');
    if (end != null) p.children.add(_renamed(end.copy(), 'endParaRPr'));
    return p;
  }

  // ---------------------------------------------------------------------------
  // Formatting a whole shape

  static const _rPrOrder = [
    'ln', 'noFill', 'solidFill', 'gradFill', 'blipFill', 'pattFill', 'grpFill', 'effectLst', 'effectDag', 'highlight', //
    'uLnTx', 'uLn', 'uFillTx', 'uFill', 'latin', 'ea', 'cs', 'sym', 'hlinkClick', 'hlinkMouseOver', 'rtl', 'extLst',
  ];

  /// Every run and paragraph mark in a shape.
  List<XmlElement> _charProps(XmlElement sp) {
    final out = <XmlElement>[];
    for (final p in sp.kid('txBody')?.kids('p') ?? const <XmlElement>[]) {
      for (final r in p.childElements.where((c) => c.name.local == 'r' || c.name.local == 'fld' || c.name.local == 'br')) {
        var rPr = r.kid('rPr');
        if (rPr == null) {
          rPr = _a('rPr', {'lang': 'en-US', 'dirty': '0'});
          r.children.insert(0, rPr);
        }
        out.add(rPr);
      }
      var end = p.kid('endParaRPr');
      if (end == null) {
        end = _a('endParaRPr', {'lang': 'en-US', 'dirty': '0'});
        p.children.add(end);
      }
      out.add(end);
    }
    return out;
  }

  void _formatShape(int slide, int ref, void Function(XmlElement rPr) change) {
    final sp = _shape(slide, ref);
    if (sp.name.local != 'sp') return;
    _pkg.checkpoint();
    for (final rPr in _charProps(sp)) {
      change(rPr);
    }
    _refresh(slide);
  }

  void setBold(int slide, int ref, bool on) => _formatShape(slide, ref, (rPr) => rPr.setAttribute('b', on ? '1' : '0'));

  void setItalic(int slide, int ref, bool on) => _formatShape(slide, ref, (rPr) => rPr.setAttribute('i', on ? '1' : '0'));

  void setUnderline(int slide, int ref, bool on) => _formatShape(slide, ref, (rPr) => rPr.setAttribute('u', on ? 'sng' : 'none'));

  /// Font size in points (stored in hundredths).
  void setFontSize(int slide, int ref, double points) =>
      _formatShape(slide, ref, (rPr) => rPr.setAttribute('sz', '${(points * 100).round().clamp(100, 400000)}'));

  /// Scales every font size in a shape, as PowerPoint's grow/shrink buttons do.
  void scaleFontSize(int slide, int ref, double factor) {
    final shape = _presentation.slides[slide].shapes.firstWhere((s) => s.ref == ref);
    final sizes = shape.paragraphs.expand((p) => p.runs).map((r) => r.fontSizePt).whereType<double>().toList();
    final base = sizes.isEmpty ? 18.0 : sizes.reduce((a, b) => a > b ? a : b);
    setFontSize(slide, ref, (base * factor).roundToDouble().clamp(6, 200));
  }

  /// Text colour as RGB hex.
  void setColor(int slide, int ref, String rgb) => _formatShape(slide, ref, (rPr) {
        for (final fill in const ['noFill', 'solidFill', 'gradFill', 'blipFill', 'pattFill', 'grpFill']) {
          removeKids(rPr, fill);
        }
        putInOrder(rPr, _a('solidFill')..children.add(_a('srgbClr', {'val': rgb})), _rPrOrder);
      });

  /// Typeface for Latin and complex-script text, e.g. Calibri or Arial.
  void setFont(int slide, int ref, String font) => _formatShape(slide, ref, (rPr) {
        putInOrder(rPr, _a('latin', {'typeface': font}), _rPrOrder);
        putInOrder(rPr, _a('cs', {'typeface': font}), _rPrOrder);
      });

  /// Paragraph alignment: l, ctr, r or just.
  void setAlignment(int slide, int ref, String align) {
    final sp = _shape(slide, ref);
    if (sp.name.local != 'sp') return;
    _pkg.checkpoint();
    for (final p in sp.kid('txBody')?.kids('p') ?? const <XmlElement>[]) {
      var pPr = p.kid('pPr');
      if (pPr == null) {
        pPr = _a('pPr');
        p.children.insert(0, pPr);
      }
      pPr.setAttribute('algn', align);
    }
    _refresh(slide);
  }

  // ---------------------------------------------------------------------------
  // Position and size

  /// Moves and resizes a shape (EMU). Placeholders that inherit their
  /// position from the layout get their own.
  void setRect(int slide, int ref, EmuRect rect) {
    final el = _shape(slide, ref);
    final isFrame = el.name.local == 'graphicFrame';
    var holder = isFrame ? el : el.kid('spPr');
    if (holder == null) {
      holder = XmlElement(XmlName.parts('spPr', prefix: el.name.prefix));
      final nv = el.childElements.first;
      el.children.insert(el.children.indexOf(nv) + 1, holder);
    }
    var xfrm = holder.kid('xfrm');
    if (xfrm == null) {
      xfrm = isFrame ? XmlElement(XmlName.parts('xfrm', prefix: el.name.prefix)) : _a('xfrm');
      if (isFrame) {
        final graphic = el.kid('graphic');
        el.children.insert(graphic == null ? el.children.length : el.children.indexOf(graphic), xfrm);
      } else {
        holder.children.insert(0, xfrm);
      }
    }
    _pkg.checkpoint();
    removeKids(xfrm, 'off');
    removeKids(xfrm, 'ext');
    xfrm.children.insertAll(0, [
      _a('off', {'x': '${rect.x}', 'y': '${rect.y}'}),
      _a('ext', {'cx': '${rect.width.clamp(1, 51206400)}', 'cy': '${rect.height.clamp(1, 51206400)}'}),
    ]);
    _refresh(slide);
  }

  // ---------------------------------------------------------------------------
  // Shapes

  int _nextShapeId(XmlDocument doc) =>
      doc.rootElement.deep('cNvPr').map((e) => int.tryParse(e.attr('id') ?? '') ?? 0).fold(1, (a, b) => a > b ? a : b) + 1;

  /// Adds a text box in the middle of the slide and returns its ref.
  int addTextBox(int slide, String text) {
    final part = _slideParts[slide];
    final doc = _pkg.xml(part)!;
    _declareA(doc);
    final tree = doc.rootElement.kid('cSld')!.kid('spTree')!;
    final id = _nextShapeId(doc);
    final p = tree.name.prefix ?? 'p';
    final w = _presentation.slideWidth;
    final h = _presentation.slideHeight;
    final boxW = (w * 0.6).round();
    final boxH = (h * 0.15).round();
    final sp = XmlDocumentFragment.parse(
      '<$p:sp xmlns:$p="$_pNs" xmlns:a="$_aNs"><$p:nvSpPr><$p:cNvPr id="$id" name="TextBox ${id - 1}"/><$p:cNvSpPr txBox="1"/><$p:nvPr/></$p:nvSpPr>'
      '<$p:spPr><a:xfrm><a:off x="${(w - boxW) ~/ 2}" y="${(h - boxH) ~/ 2}"/><a:ext cx="$boxW" cy="$boxH"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></$p:spPr>'
      '<$p:txBody><a:bodyPr wrap="square" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>'
      '<a:p><a:r><a:rPr lang="en-US" sz="2400" dirty="0"><a:latin typeface="Calibri"/></a:rPr><a:t>${EditablePackage.escape(text)}</a:t></a:r></a:p></$p:txBody></$p:sp>',
    ).firstElementChild!.copy();
    sp.removeAttribute('xmlns:$p');
    sp.removeAttribute('xmlns:a');
    _pkg.checkpoint();
    tree.children.add(sp);
    _refresh(slide);
    return _shapes[slide].indexOf(sp);
  }

  void deleteShape(int slide, int ref) {
    _pkg.checkpoint();
    _shape(slide, ref).remove();
    _refresh(slide);
  }

  // ---------------------------------------------------------------------------
  // Slides

  XmlElement get _sldIdLst {
    final root = _pres.rootElement;
    var list = root.kid('sldIdLst');
    if (list == null) {
      list = XmlElement(XmlName.parts('sldIdLst', prefix: root.name.prefix));
      final masters = root.kid('sldMasterIdLst');
      root.children.insert(masters == null ? 0 : root.children.indexOf(masters) + 1, list);
      // notesMasterIdLst and handoutMasterIdLst come between; move after them.
      for (final name in const ['notesMasterIdLst', 'handoutMasterIdLst']) {
        final el = root.kid(name);
        if (el != null && root.children.indexOf(el) > root.children.indexOf(list)) {
          list.remove();
          root.children.insert(root.children.indexOf(el) + 1, list);
        }
      }
    }
    return list;
  }

  List<XmlElement> get _slideIds {
    final rels = _pkg.relationships(_presPart);
    return [
      for (final id in _sldIdLst.kids('sldId'))
        if (rels[id.relId] != null && _pkg.xml(rels[id.relId]!) != null) id,
    ];
  }

  String _newSlidePart() {
    var n = 1;
    while (_pkg.has('ppt/slides/slide$n.xml')) {
      n++;
    }
    return 'ppt/slides/slide$n.xml';
  }

  /// Adds [doc] as a new slide part after slide [after] and returns its index.
  int _insertSlide(XmlDocument doc, Map<String, String> rels, int after) {
    final part = _newSlidePart();
    _pkg.put(part, doc);
    _pkg.addOverride('/$part', _slideContentType);
    final relsDoc = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>');
    for (final e in rels.entries) {
      relsDoc.rootElement.children.add(XmlElement(XmlName.parts('Relationship'), [
        XmlAttribute(XmlName.parts('Id'), e.key),
        XmlAttribute(XmlName.parts('Type'), e.value.split('|').first),
        XmlAttribute(XmlName.parts('Target'), e.value.split('|').last),
        if (e.value.split('|').length == 3) XmlAttribute(XmlName.parts('TargetMode'), e.value.split('|')[1]),
      ]));
    }
    _pkg.put(EditablePackage.relsPath(part), relsDoc);
    final rid = _pkg.addRelationship(_presPart, _slideType, part.substring('ppt/'.length));
    final list = _sldIdLst;
    final ids = list.kids('sldId').map((e) => int.tryParse(e.attr('id') ?? '') ?? 0);
    final nextId = ids.fold(255, (a, b) => a > b ? a : b) + 1;
    final prefix = list.name.prefix;
    final rPrefix = _pres.rootElement.attributes.firstWhere((a) => a.name.prefix == 'xmlns' && a.value == EditablePackage.relNs).name.local;
    final entry = XmlElement(XmlName.parts('sldId', prefix: prefix), [
      XmlAttribute(XmlName.parts('id'), '$nextId'),
      XmlAttribute(XmlName.parts('id', prefix: rPrefix), rid),
    ]);
    final existing = _slideIds;
    if (after < 0 || existing.isEmpty) {
      list.children.insert(0, entry);
    } else {
      final anchor = existing[after.clamp(0, existing.length - 1)];
      list.children.insert(list.children.indexOf(anchor) + 1, entry);
    }
    _pkg.touch(_presPart);
    _reload();
    return after + 1;
  }

  /// Copies slide [index] (without its speaker notes) and puts the copy
  /// right after it.
  int duplicateSlide(int index) {
    _pkg.checkpoint();
    final part = _slideParts[index];
    final copy = XmlDocument.parse(_pkg.xml(part)!.toXmlString());
    final rels = <String, String>{};
    for (final e in _pkg.relationshipElements(part).entries) {
      final type = e.value.attr('Type') ?? '';
      if (type.endsWith('/notesSlide')) continue;
      final mode = e.value.attr('TargetMode');
      rels[e.key] = mode == null ? '$type|${e.value.attr('Target')}' : '$type|$mode|${e.value.attr('Target')}';
    }
    return _insertSlide(copy, rels, index);
  }

  /// Adds a slide with the same layout as slide [after], with that layout's
  /// empty placeholders, and returns its index.
  /// The "Title and Content" layout of [layoutPart]'s slide master, if any.
  String? _contentLayout(String layoutPart) {
    final master = _pkg.relationshipOfType(layoutPart, '/slideMaster');
    if (master == null) return null;
    for (final r in _pkg.relationshipElements(master).values) {
      if (!(r.attr('Type') ?? '').endsWith('/slideLayout')) continue;
      final part = _pkg.target(master, r);
      if (_pkg.xml(part)?.rootElement.attr('type') == 'obj') return part;
    }
    return null;
  }

  int addSlide(int after) {
    final reference = _slideParts.isEmpty ? null : _slideParts[after.clamp(0, _slideParts.length - 1)];
    String? layoutTarget;
    String? layoutPart;
    if (reference != null) {
      for (final r in _pkg.relationshipElements(reference).values) {
        if ((r.attr('Type') ?? '').endsWith('/slideLayout')) {
          layoutTarget = r.attr('Target');
          layoutPart = _pkg.target(reference, r);
        }
      }
    }
    if (layoutTarget == null || layoutPart == null) {
      throw const EditRefused('This presentation has no slide layout to base a new slide on.');
    }
    // After a title slide, the next slide is normally a title-and-content one.
    if (_pkg.xml(layoutPart)?.rootElement.attr('type') == 'title') {
      final content = _contentLayout(layoutPart);
      if (content != null && reference!.startsWith('ppt/slides/') && content.startsWith('ppt/')) {
        layoutPart = content;
        layoutTarget = '../${content.substring(4)}';
      }
    }
    _pkg.checkpoint();
    final layout = _pkg.xml(layoutPart);
    final placeholders = StringBuffer();
    var id = 2;
    for (final sp in layout?.rootElement.kid('cSld')?.kid('spTree')?.kids('sp') ?? const <XmlElement>[]) {
      final ph = sp.kid('nvSpPr')?.kid('nvPr')?.kid('ph');
      if (ph == null || const {'dt', 'ftr', 'sldNum'}.contains(ph.attr('type'))) continue;
      final attrs = [
        if (ph.attr('type') != null) 'type="${ph.attr('type')}"',
        if (ph.attr('orient') != null) 'orient="${ph.attr('orient')}"',
        if (ph.attr('sz') != null) 'sz="${ph.attr('sz')}"',
        if (ph.attr('idx') != null) 'idx="${ph.attr('idx')}"',
      ].join(' ');
      final name = EditablePackage.escape(sp.kid('nvSpPr')?.kid('cNvPr')?.attr('name') ?? 'Placeholder $id');
      placeholders.write('<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
          '<p:nvPr><p:ph $attrs/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US" dirty="0"/></a:p></p:txBody></p:sp>');
      id++;
    }
    final doc = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sld xmlns:a="$_aNs" xmlns:r="${EditablePackage.relNs}" xmlns:p="$_pNs"><p:cSld><p:spTree>'
        '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
        '$placeholders</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>');
    return _insertSlide(doc, {'rId1': '${EditablePackage.relNs}/slideLayout|$layoutTarget'}, after);
  }

  /// Removes slide [index] with its speaker notes. A presentation keeps at
  /// least one slide.
  void deleteSlide(int index) {
    final ids = _slideIds;
    if (ids.length <= 1) throw const EditRefused('A presentation needs at least one slide.');
    _pkg.checkpoint();
    final part = _slideParts[index];
    final entry = ids[index];
    final rid = entry.relId;
    entry.remove();
    final presRels = _pkg.xml(EditablePackage.relsPath(_presPart))!;
    presRels.rootElement.children.removeWhere((n) => n is XmlElement && n.attr('Id') == rid);
    _pkg.touch(EditablePackage.relsPath(_presPart));
    _pkg.touch(_presPart);
    final notes = _pkg.relationshipOfType(part, '/notesSlide');
    for (final p in [part, ?notes]) {
      _pkg.remove(p);
      _pkg.remove(EditablePackage.relsPath(p));
      final types = _pkg.xml('[Content_Types].xml')!;
      types.rootElement.children.removeWhere((n) => n is XmlElement && n.attr('PartName') == '/$p');
      _pkg.touch('[Content_Types].xml');
    }
    _reload();
  }

  /// Moves slide [from] to position [to].
  void moveSlide(int from, int to) {
    final ids = _slideIds;
    if (from == to || to < 0 || to >= ids.length) return;
    _pkg.checkpoint();
    final list = _sldIdLst;
    final entry = ids[from]..remove();
    final remaining = list.kids('sldId').toList();
    if (to >= remaining.length) {
      list.children.insert(list.children.indexOf(remaining.last) + 1, entry);
    } else {
      list.children.insert(list.children.indexOf(remaining[to]), entry);
    }
    _pkg.touch(_presPart);
    _reload();
  }
}
