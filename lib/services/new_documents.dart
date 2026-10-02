import 'dart:async';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'ooxml/docx_reader.dart';
import 'ooxml/docx_writer.dart';
import 'ooxml/ooxml_writer.dart';
import 'ooxml/pptx_writer.dart';
import 'ooxml/xlsx_editor.dart';
import 'ooxml/xlsx_reader.dart';
import 'ooxml/xlsx_writer.dart';

/// Kinds of file the app can create from scratch.
enum NewKind {
  word('Word document', 'docx'),
  excel('Excel workbook', 'xlsx'),
  powerpoint('PowerPoint presentation', 'pptx'),
  pdf('PDF', 'pdf');

  const NewKind(this.label, this.extension);

  final String label;
  final String extension;
}

/// A starting point for a new file.
class NewTemplate {
  const NewTemplate(this.kind, this.name, this.description, this._build);

  final NewKind kind;
  final String name;
  final String description;
  final FutureOr<Uint8List> Function(String title) _build;

  /// The new file's bytes, with [title] as its document title.
  Future<Uint8List> build(String title) async => _build(title);
}

/// Every template, blank first within each kind.
final List<NewTemplate> newTemplates = [
  NewTemplate(NewKind.word, 'Blank', 'An empty page', _blankDocument),
  NewTemplate(NewKind.word, 'Letter', 'Addresses, date and a signature', _letter),
  NewTemplate(NewKind.word, 'Resume', 'Experience, education and skills', _resume),
  NewTemplate(NewKind.word, 'Meeting notes', 'Agenda, notes and action items', _meetingNotes),
  NewTemplate(NewKind.excel, 'Blank', 'An empty sheet', _blankWorkbook),
  NewTemplate(NewKind.excel, 'Budget', 'Planned and actual spending with totals', _budget),
  NewTemplate(NewKind.excel, 'Invoice', 'Items, tax and a total that add up', _invoice),
  NewTemplate(NewKind.excel, 'To-do list', 'Tasks, due dates and status', _todo),
  NewTemplate(NewKind.powerpoint, 'Blank', 'A title slide', _blankPresentation),
  NewTemplate(NewKind.powerpoint, 'Project update', 'Goals, progress and next steps', _projectUpdate),
  NewTemplate(NewKind.pdf, 'Blank page', 'One empty A4 page to write or sign on', _blankPdf),
];

// -----------------------------------------------------------------------------
// Word

DocxParagraph _p(String text, {bool bold = false, ParagraphAlign align = ParagraphAlign.left, double? size, String? color}) =>
    DocxParagraph(runs: [if (text.isNotEmpty) DocxRun(text, bold: bold, fontSizePt: size, color: color)], align: align);

DocxParagraph _heading(String text, [int level = 1]) => DocxParagraph(runs: [DocxRun(text)], headingLevel: level);

DocxParagraph _bullet(String text) => DocxParagraph(runs: [DocxRun(text)], listLevel: 0);

Uint8List _word(String title, List<DocxBlock> blocks) => DocxWriter.write(DocxDocument(blocks), title: title);

String _today() {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final d = DateTime.now();
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

Uint8List _blankDocument(String title) => _word(title, [_p('')]);

Uint8List _letter(String title) => _word(title, [
      _p('Your name', bold: true),
      _p('Street address'),
      _p('City, postcode'),
      _p('Phone · email'),
      _p(''),
      _p(_today()),
      _p(''),
      _p('Recipient name'),
      _p('Company'),
      _p('Street address'),
      _p('City, postcode'),
      _p(''),
      _p('Dear Recipient,'),
      _p(''),
      _p('Write the first paragraph of your letter here. Say why you are writing.'),
      _p(''),
      _p('Add the details in a second paragraph.'),
      _p(''),
      _p('Yours sincerely,'),
      _p(''),
      _p(''),
      _p('Your name'),
    ]);

Uint8List _resume(String title) => _word(title, [
      DocxParagraph(runs: const [DocxRun('Your Name')], isTitle: true),
      _p('City · phone · email · linkedin.com/in/you', color: '595959'),
      _heading('Summary'),
      _p('Two or three sentences about who you are and the work you want next.'),
      _heading('Experience'),
      DocxParagraph(runs: const [DocxRun('Job title', bold: true), DocxRun(' · Company · 2022 to now')]),
      _bullet('What you achieved, with a number if you can.'),
      _bullet('Another result you are proud of.'),
      DocxParagraph(runs: const [DocxRun('Job title', bold: true), DocxRun(' · Company · 2019 to 2022')]),
      _bullet('What you were responsible for.'),
      _heading('Education'),
      DocxParagraph(runs: const [DocxRun('Degree', bold: true), DocxRun(' · University · Year')]),
      _heading('Skills'),
      _bullet('Skill one'),
      _bullet('Skill two'),
      _bullet('Skill three'),
    ]);

Uint8List _meetingNotes(String title) => _word(title, [
      DocxParagraph(runs: const [DocxRun('Meeting notes')], isTitle: true),
      DocxParagraph(runs: [const DocxRun('Date: ', bold: true), DocxRun(_today())]),
      const DocxParagraph(runs: [DocxRun('Attendees: ', bold: true), DocxRun('Names')]),
      _heading('Agenda'),
      _bullet('First topic'),
      _bullet('Second topic'),
      _heading('Notes'),
      _p('What was discussed and decided.'),
      _heading('Action items'),
      const DocxTable([
        ['Action', 'Owner', 'Due'],
        ['', '', ''],
        ['', '', ''],
      ]),
    ]);

// -----------------------------------------------------------------------------
// Excel

/// Builds a workbook: [values] are written first (they size the columns),
/// then [inputs] are typed in as if by hand (formulas are worked out), then
/// [style] runs on the editor.
Uint8List _workbook(String title, String sheet, Map<(int, int), String> values,
    {Map<(int, int), String> inputs = const {}, Map<int, double> widths = const {}, void Function(XlsxEditor e)? style}) {
  final cells = {for (final e in values.entries) e.key: XlsxCell(e.value)};
  final base = XlsxWriter.write(XlsxWorkbook([XlsxSheet(sheet, cells, columnWidths: widths)]), title: title);
  if (inputs.isEmpty && style == null) return base;
  final editor = XlsxEditor.open(base);
  for (final e in inputs.entries) {
    editor.setCell(0, e.key.$1, e.key.$2, e.value);
  }
  style?.call(editor);
  return editor.save();
}

Iterable<(int, int)> _row(int r, int from, int to) sync* {
  for (var c = from; c <= to; c++) {
    yield (r, c);
  }
}

Iterable<(int, int)> _column(int c, int from, int to) sync* {
  for (var r = from; r <= to; r++) {
    yield (r, c);
  }
}

const _headerFill = 'DDEBF7';
const _totalFill = 'F2F2F2';

/// Excel's built-in `#,##0.00` format.
const _money = 4;

Uint8List _blankWorkbook(String title) => _workbook(title, 'Sheet1', const {});

Uint8List _budget(String title) {
  const lines = [
    ('Income', 'Salary', '3,000.00', '3,000.00'),
    ('Income', 'Other income', '200.00', '150.00'),
    ('Expense', 'Rent', '1,000.00', '1,000.00'),
    ('Expense', 'Groceries', '400.00', '430.00'),
    ('Expense', 'Transport', '150.00', '120.00'),
    ('Expense', 'Bills and phone', '200.00', '210.00'),
    ('Expense', 'Fun and eating out', '250.00', '310.00'),
    ('Expense', 'Savings', '500.00', '500.00'),
  ];
  final values = <(int, int), String>{
    (0, 0): 'Monthly budget',
    (2, 0): 'Type',
    (2, 1): 'Item',
    (2, 2): 'Planned',
    (2, 3): 'Actual',
    (2, 4): 'Difference',
  };
  final inputs = <(int, int), String>{};
  for (var i = 0; i < lines.length; i++) {
    final r = 3 + i;
    values[(r, 0)] = lines[i].$1;
    values[(r, 1)] = lines[i].$2;
    inputs[(r, 2)] = lines[i].$3;
    inputs[(r, 3)] = lines[i].$4;
    inputs[(r, 4)] = '=D${r + 1}-C${r + 1}';
  }
  // Excel row numbers of the first and last line; the total goes right below.
  const first = 4;
  final last = 3 + lines.length;
  final total = 3 + lines.length;
  values[(total, 1)] = 'Left over (income minus expenses)';
  for (final (c, letter) in [(2, 'C'), (3, 'D')]) {
    inputs[(total, c)] = '=SUMIF(A$first:A$last,"Income",$letter$first:$letter$last)-SUMIF(A$first:A$last,"Expense",$letter$first:$letter$last)';
  }
  inputs[(total, 4)] = '=D${total + 1}-C${total + 1}';
  return _workbook(title, 'Budget', values, inputs: inputs, widths: const {0: 12, 1: 34, 2: 14, 3: 14, 4: 14}, style: (e) {
    for (final c in [2, 3, 4]) {
      e.setNumberFormat(0, _column(c, 3, total), _money);
    }
    e.setBold(0, const [(0, 0)], true);
    e.setFontColor(0, const [(0, 0)], '1F4E79');
    e.setBold(0, _row(2, 0, 4), true);
    e.setFill(0, _row(2, 0, 4), _headerFill);
    e.setBold(0, _row(total, 0, 4), true);
    e.setFill(0, _row(total, 0, 4), _totalFill);
  });
}

Uint8List _invoice(String title) {
  const items = [
    ('Design work', '10', '50.00'),
    ('Printing', '200', '0.75'),
    ('Delivery', '1', '25.00'),
  ];
  final values = <(int, int), String>{
    (0, 0): 'INVOICE',
    (1, 0): 'Your business name',
    (2, 0): 'Address · phone · email',
    (4, 0): 'Bill to:',
    (5, 0): 'Customer name',
    (6, 0): 'Customer address',
    (4, 2): 'Invoice no.',
    (4, 3): '0001',
    (5, 2): 'Date',
    (8, 0): 'Description',
    (8, 1): 'Quantity',
    (8, 2): 'Unit price',
    (8, 3): 'Amount',
  };
  final inputs = <(int, int), String>{
    // Typed so it stays text with its leading zeros.
    (4, 3): "'0001",
    (5, 3): () {
      final d = DateTime.now();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }(),
  };
  for (var i = 0; i < items.length; i++) {
    final r = 9 + i;
    values[(r, 0)] = items[i].$1;
    inputs[(r, 1)] = items[i].$2;
    inputs[(r, 2)] = items[i].$3;
    inputs[(r, 3)] = '=IF(B${r + 1}="","",B${r + 1}*C${r + 1})';
  }
  // Room for more items before the totals.
  const firstItem = 10;
  const lastItem = 17;
  for (var r = 9 + items.length; r < lastItem; r++) {
    inputs[(r, 3)] = '=IF(B${r + 1}="","",B${r + 1}*C${r + 1})';
  }
  // Excel row number of the subtotal; tax rate, tax and total follow it.
  const subtotal = lastItem + 1;
  values[(subtotal - 1, 2)] = 'Subtotal';
  inputs[(subtotal - 1, 3)] = '=SUM(D$firstItem:D$lastItem)';
  values[(subtotal, 2)] = 'Tax rate';
  inputs[(subtotal, 3)] = '10%';
  values[(subtotal + 1, 2)] = 'Tax';
  inputs[(subtotal + 1, 3)] = '=ROUND(D$subtotal*D${subtotal + 1},2)';
  values[(subtotal + 2, 2)] = 'Total';
  inputs[(subtotal + 2, 3)] = '=D$subtotal+D${subtotal + 2}';
  values[(subtotal + 4, 0)] = 'Thank you for your business.';
  return _workbook(title, 'Invoice', values, inputs: inputs, widths: const {0: 30, 1: 12, 2: 14, 3: 14}, style: (e) {
    e.setNumberFormat(0, [..._column(2, 9, lastItem - 1), ..._column(3, 9, lastItem - 1), (subtotal - 1, 3), (subtotal + 1, 3), (subtotal + 2, 3)], _money);
    e.setBold(0, const [(0, 0)], true);
    e.setFontColor(0, const [(0, 0)], '1F4E79');
    e.setBold(0, const [(4, 0), (4, 2), (5, 2)], true);
    e.setBold(0, _row(8, 0, 3), true);
    e.setFill(0, _row(8, 0, 3), _headerFill);
    e.setAlignment(0, _row(8, 1, 3), 'right');
    e.setAlignment(0, const [(4, 3), (5, 3)], 'right');
    e.setAlignment(0, _column(2, subtotal - 1, subtotal + 2), 'right');
    e.setBold(0, _row(subtotal + 2, 2, 3), true);
    e.setFill(0, _row(subtotal + 2, 2, 3), _totalFill);
  });
}

Uint8List _todo(String title) {
  final values = <(int, int), String>{
    (0, 0): 'To-do list',
    (2, 0): 'Task',
    (2, 1): 'Due',
    (2, 2): 'Status',
    (2, 3): 'Notes',
    (3, 0): 'First thing to do',
    (3, 2): 'Not started',
    (4, 0): 'Another task',
    (4, 2): 'In progress',
    (5, 0): 'Something already finished',
    (5, 2): 'Done',
  };
  return _workbook(title, 'To-do', values, widths: const {0: 34, 1: 12, 2: 14, 3: 40}, style: (e) {
    e.setBold(0, const [(0, 0)], true);
    e.setFontColor(0, const [(0, 0)], '1F4E79');
    e.setBold(0, _row(2, 0, 3), true);
    e.setFill(0, _row(2, 0, 3), _headerFill);
  });
}

// -----------------------------------------------------------------------------
// PowerPoint

/// A slide in a new presentation: a title slide (title and subtitle) or a
/// title-and-content slide (title and bullet points).
class _Slide {
  const _Slide.title(this.title, [this.subtitle = '']) : bullets = const [], isTitle = true;
  const _Slide.content(this.title, this.bullets) : subtitle = '', isTitle = false;

  final bool isTitle;
  final String title;
  final String subtitle;
  final List<String> bullets;
}

Uint8List _blankPresentation(String title) => _presentation(title, const [_Slide.title('', '')]);

Uint8List _projectUpdate(String title) => _presentation(title, const [
      _Slide.title('Project update', 'Team name · date'),
      _Slide.content('Goals', ['What we set out to do', 'How we measure success']),
      _Slide.content('Progress', ['What is done', 'What is in progress', 'Numbers that show it']),
      _Slide.content('Risks and help needed', ['What could slow us down', 'Decisions we need']),
      _Slide.content('Next steps', ['Next milestone and date', 'Who does what']),
    ]);

const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _pNs = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _ns = 'xmlns:a="$_a" xmlns:r="$_r" xmlns:p="$_pNs"';
const _ct = 'application/vnd.openxmlformats-officedocument.presentationml';
const _group = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

String _xfrm(int x, int y, int w, int h) => '<a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm>';

/// A placeholder shape. [spPr] positions it (empty to inherit), [body] is
/// its bodyPr and lstStyle, [paragraphs] its text.
String _placeholder(int id, String name, String ph, {String spPr = '', String body = '<a:bodyPr/><a:lstStyle/>', String paragraphs = ''}) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph $ph/></p:nvPr></p:nvSpPr>'
    '<p:spPr>$spPr</p:spPr><p:txBody>$body${paragraphs.isEmpty ? '<a:p><a:endParaRPr lang="en-US" dirty="0"/></a:p>' : paragraphs}</p:txBody></p:sp>';

String _para(String text) => text.isEmpty
    ? '<a:p><a:endParaRPr lang="en-US" dirty="0"/></a:p>'
    : '<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>${OoxmlPackageWriter.esc(text)}</a:t></a:r></a:p>';

String _level(int lvl, int marL, int size, {bool bullet = true}) => '<a:lvl${lvl}pPr marL="$marL" indent="${bullet ? -228600 : 0}" algn="l">'
    '<a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPts val="1000"/></a:spcBef>'
    '${bullet ? '<a:buFont typeface="Arial"/><a:buChar char="•"/>' : '<a:buNone/>'}'
    '<a:defRPr sz="$size" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl${lvl}pPr>';

/// A 16:9 presentation on the Office theme with PowerPoint's standard
/// Title Slide, Title and Content, Title Only and Blank layouts, so slides
/// added later in PowerPoint (or in the app) get proper placeholders.
Uint8List _presentation(String title, List<_Slide> slides) {
  const width = 12192000;
  const height = 6858000;
  final pkg = OoxmlPackageWriter();

  // Master: title and body placeholders, with Office's text styles.
  final masterShapes = _placeholder(2, 'Title Placeholder 1', 'type="title"',
          spPr: _xfrm(838200, 365125, 10515600, 1325563),
          body: '<a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0" anchor="ctr"><a:normAutofit/></a:bodyPr><a:lstStyle/>',
          paragraphs: _para('Click to edit Master title style')) +
      _placeholder(3, 'Text Placeholder 2', 'type="body" idx="1"',
          spPr: _xfrm(838200, 1825625, 10515600, 4351338),
          body: '<a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>',
          paragraphs: _para('Click to edit Master text styles'));
  pkg.addXml(
    'ppt/slideMasters/slideMaster1.xml',
    '<p:sldMaster $_ns><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>$_group$masterShapes</p:spTree></p:cSld>'
        '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" '
        'accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
        '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/><p:sldLayoutId id="2147483650" r:id="rId2"/>'
        '<p:sldLayoutId id="2147483651" r:id="rId3"/><p:sldLayoutId id="2147483652" r:id="rId4"/></p:sldLayoutIdLst>'
        '<p:txStyles><p:titleStyle><a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">'
        '<a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPct val="0"/></a:spcBef><a:buNone/>'
        '<a:defRPr sz="4400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>'
        '<p:bodyStyle>${_level(1, 228600, 2800)}${_level(2, 685800, 2400)}${_level(3, 1143000, 2000)}${_level(4, 1600200, 1800)}${_level(5, 2057400, 1800)}</p:bodyStyle>'
        '<p:otherStyle><a:lvl1pPr marL="0" algn="l" defTabSz="914400"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>'
        '<a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>',
    contentType: '$_ct.slideMaster+xml',
  );
  pkg.addXml(
    'ppt/slideMasters/_rels/slideMaster1.xml.rels',
    OoxmlPackageWriter.rels([
      for (var i = 1; i <= 4; i++) ('rId$i', OoxmlPackageWriter.relType('slideLayout'), '../slideLayouts/slideLayout$i.xml'),
      ('rId5', OoxmlPackageWriter.relType('theme'), '../theme/theme1.xml'),
    ]),
  );

  // Layouts.
  final layouts = [
    (
      'title',
      'Title Slide',
      _placeholder(2, 'Title 1', 'type="ctrTitle"',
              spPr: _xfrm(1524000, 1122363, 9144000, 2387600),
              body: '<a:bodyPr anchor="b"/><a:lstStyle><a:lvl1pPr algn="ctr"><a:defRPr sz="6000"/></a:lvl1pPr></a:lstStyle>',
              paragraphs: _para('Click to edit Master title style')) +
          _placeholder(3, 'Subtitle 2', 'type="subTitle" idx="1"',
              spPr: _xfrm(1524000, 3602038, 9144000, 1655762),
              body: '<a:bodyPr/><a:lstStyle><a:lvl1pPr marL="0" indent="0" algn="ctr"><a:buNone/><a:defRPr sz="2400"/></a:lvl1pPr></a:lstStyle>',
              paragraphs: _para('Click to edit Master subtitle style')),
    ),
    (
      'obj',
      'Title and Content',
      _placeholder(2, 'Title 1', 'type="title"', paragraphs: _para('Click to edit Master title style')) +
          _placeholder(3, 'Content Placeholder 2', 'idx="1"', paragraphs: _para('Click to edit Master text styles')),
    ),
    ('titleOnly', 'Title Only', _placeholder(2, 'Title 1', 'type="title"', paragraphs: _para('Click to edit Master title style'))),
    ('blank', 'Blank', ''),
  ];
  for (var i = 0; i < layouts.length; i++) {
    final (type, name, shapes) = layouts[i];
    pkg.addXml(
      'ppt/slideLayouts/slideLayout${i + 1}.xml',
      '<p:sldLayout $_ns type="$type" preserve="1"><p:cSld name="$name"><p:spTree>$_group$shapes</p:spTree></p:cSld>'
          '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>',
      contentType: '$_ct.slideLayout+xml',
    );
    pkg.addXml(
      'ppt/slideLayouts/_rels/slideLayout${i + 1}.xml.rels',
      OoxmlPackageWriter.rels([('rId1', OoxmlPackageWriter.relType('slideMaster'), '../slideMasters/slideMaster1.xml')]),
    );
  }
  pkg.addXml('ppt/theme/theme1.xml', PptxWriter.officeTheme, contentType: 'application/vnd.openxmlformats-officedocument.theme+xml');

  // Slides.
  final presRels = <(String, String, String)>[
    ('rId1', OoxmlPackageWriter.relType('slideMaster'), 'slideMasters/slideMaster1.xml'),
    ('rId2', OoxmlPackageWriter.relType('theme'), 'theme/theme1.xml'),
  ];
  final ids = StringBuffer();
  for (var i = 0; i < slides.length; i++) {
    final n = i + 1;
    final s = slides[i];
    final shapes = s.isTitle
        ? _placeholder(2, 'Title 1', 'type="ctrTitle"', paragraphs: _para(s.title)) +
            _placeholder(3, 'Subtitle 2', 'type="subTitle" idx="1"', paragraphs: _para(s.subtitle))
        : _placeholder(2, 'Title 1', 'type="title"', paragraphs: _para(s.title)) +
            _placeholder(3, 'Content Placeholder 2', 'idx="1"', paragraphs: s.bullets.map(_para).join());
    pkg.addXml(
      'ppt/slides/slide$n.xml',
      '<p:sld $_ns><p:cSld><p:spTree>$_group$shapes</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>',
      contentType: '$_ct.slide+xml',
    );
    pkg.addXml(
      'ppt/slides/_rels/slide$n.xml.rels',
      OoxmlPackageWriter.rels([('rId1', OoxmlPackageWriter.relType('slideLayout'), '../slideLayouts/slideLayout${s.isTitle ? 1 : 2}.xml')]),
    );
    presRels.add(('rId${n + 2}', OoxmlPackageWriter.relType('slide'), 'slides/slide$n.xml'));
    ids.write('<p:sldId id="${255 + n}" r:id="rId${n + 2}"/>');
  }
  pkg.addXml(
    'ppt/presentation.xml',
    '<p:presentation $_ns saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '<p:sldIdLst>$ids</p:sldIdLst><p:sldSz cx="$width" cy="$height"/><p:notesSz cx="6858000" cy="9144000"/>'
        '<p:defaultTextStyle><a:lvl1pPr marL="0" algn="l" defTabSz="914400"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>'
        '<a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:defaultTextStyle></p:presentation>',
    contentType: '$_ct.presentation.main+xml',
  );
  pkg.addXml('ppt/_rels/presentation.xml.rels', OoxmlPackageWriter.rels(presRels));
  pkg.addRootRels('ppt/presentation.xml');
  pkg.addDocProps(title: title);
  return pkg.build();
}

// -----------------------------------------------------------------------------
// PDF

Future<Uint8List> _blankPdf(String title) {
  final doc = pw.Document(title: title.isEmpty ? null : title, creator: 'Doc Reader');
  doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.SizedBox()));
  return doc.save();
}
