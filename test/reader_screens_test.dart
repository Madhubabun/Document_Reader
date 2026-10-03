import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:doc_reader/app_scope.dart';
import 'package:doc_reader/models/doc_file.dart';
import 'package:doc_reader/screens/office_reader_screen.dart';
import 'package:doc_reader/screens/pdf_reader_screen.dart';
import 'package:doc_reader/services/ooxml/docx_reader.dart';
import 'package:doc_reader/services/ooxml/pptx_reader.dart';
import 'package:doc_reader/services/ooxml/xlsx_reader.dart';
import 'package:doc_reader/services/library_store.dart';
import 'package:doc_reader/services/pdf_edits.dart';
import 'package:doc_reader/services/settings_store.dart';
import 'package:doc_reader/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

/// Set PDFIUM_PATH to a libpdfium build to run the PDF viewer test.
final pdfium = Platform.environment['PDFIUM_PATH'];

/// sample.pptx with its master given a picture background and the slide
/// title coloured with the theme's background colour (white on the picture),
/// the way many downloaded song and church decks are built.
List<int> deckWithMasterBackground() {
  final source = ZipDecoder().decodeBytes(File('test/fixtures/sample.pptx').readAsBytesSync());
  final out = Archive();
  const jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1];
  for (final f in source.files) {
    var bytes = f.content as List<int>;
    if (f.name == 'ppt/slideMasters/slideMaster1.xml') {
      final xml = utf8.decode(bytes).replaceFirst(RegExp(r'<p:bg>.*?</p:bg>'), '').replaceFirst('<p:cSld>',
          '<p:cSld><p:bg><p:bgPr><a:blipFill dpi="0" rotWithShape="1"><a:blip r:embed="rIdBg"/><a:stretch><a:fillRect/></a:stretch></a:blipFill><a:effectLst/></p:bgPr></p:bg>');
      bytes = utf8.encode(xml);
    } else if (f.name == 'ppt/slideMasters/_rels/slideMaster1.xml.rels') {
      bytes = utf8.encode(utf8.decode(bytes).replaceFirst('</Relationships>',
          '<Relationship Id="rIdBg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/bg.jpeg"/></Relationships>'));
    } else if (f.name == 'ppt/slides/slide1.xml') {
      // Strip any slide-level background and colour the title runs with bg1.
      final xml = utf8.decode(bytes).replaceFirst(RegExp(r'<p:bg>.*?</p:bg>'), '').replaceAll(
            '<a:r><a:t>',
            '<a:r><a:rPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill></a:rPr><a:t>',
          );
      bytes = utf8.encode(xml);
    }
    out.addFile(ArchiveFile.bytes(f.name, bytes));
  }
  out.addFile(ArchiveFile.bytes('ppt/media/bg.jpeg', jpeg));
  return ZipEncoder().encodeBytes(out);
}

void main() {
  group('PowerPoint inheritance', () {
    test('master picture background and theme text colours reach the slide', () {
      final pres = PptxReader.read(deckWithMasterBackground());
      final slide = pres.slides.first;
      expect(slide.backgroundImage, isNotNull);
      final runs = slide.shapes.expand((s) => s.paragraphs).expand((p) => p.runs).where((r) => r.text.trim().isNotEmpty);
      expect(runs, isNotEmpty);
      // bg1 maps to lt1, which is white in the default Office theme.
      expect(runs.map((r) => r.color).toSet(), {'FFFFFF'});
    });

    test('theme colours honour brightness modifiers', () {
      final colors = SchemeColors({'accent1': '4472C4', 'lt1': 'FFFFFF', 'dk1': '000000'}, {'bg1': 'lt1', 'tx1': 'dk1'});
      XmlElement holder(String color) =>
          XmlDocument.parse('<a:solidFill xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">$color</a:solidFill>').rootElement;
      expect(colors.resolve(holder('<a:schemeClr val="tx1"/>')), '000000');
      expect(colors.resolve(holder('<a:schemeClr val="tx1"><a:lumMod val="65000"/><a:lumOff val="35000"/></a:schemeClr>')), '595959');
      expect(colors.resolve(holder('<a:prstClr val="white"/>')), 'FFFFFF');
      expect(colors.resolve(holder('<a:schemeClr val="phClr"/>')), isNull);
    });
  });

  testWidgets('PDF reader opens a document without crashing', (tester) async {
    Pdfrx.pdfiumModulePath = pdfium;
    // pdfrx keeps a page cache in the temporary directory.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = Directory.systemTemp.createTempSync('pdf_reader');
    final path = '${dir.path}/Two pages.pdf';
    await tester.runAsync(() async {
      final doc = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('First page')))
        ..addPage(pw.Page(build: (_) => pw.Text('Second page')));
      await File(path).writeAsBytes(await doc.save());
    });
    final file = DocFile(path: path, name: 'Two pages.pdf', sizeBytes: 1, openedAt: DateTime.now());
    await tester.pumpWidget(AppScope(
      library: LibraryStore(prefs, dir),
      settings: SettingsStore(prefs),
      child: MaterialApp(theme: AppTheme.dark(), home: PdfReaderScreen(file: file)),
    ));
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 30 && find.textContaining('of 2').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('Page 1 of 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5)); // let the viewer's timers finish
    dir.deleteSync(recursive: true);
  }, skip: pdfium == null);

  testWidgets('PDFs can be signed with a drawn signature', (tester) async {
    Pdfrx.pdfiumModulePath = pdfium;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = Directory.systemTemp.createTempSync('pdf_sign');
    final path = '${dir.path}/Contract.pdf';
    late Uint8List original;
    await tester.runAsync(() async {
      final doc = pw.Document()..addPage(pw.Page(build: (_) => pw.Text('Sign below')));
      original = await doc.save();
      await File(path).writeAsBytes(original);
    });
    final library = LibraryStore(prefs, dir);
    final file = DocFile(path: path, name: 'Contract.pdf', sizeBytes: original.length, openedAt: DateTime.now());
    await tester.pumpWidget(AppScope(
      library: library,
      settings: SettingsStore(prefs),
      child: MaterialApp(theme: AppTheme.dark(), home: PdfReaderScreen(file: file)),
    ));
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle(() => find.textContaining('of 1').evaluate().isNotEmpty);
    await tester.tap(find.text('Sign'));
    await settle(() => find.text('Draw a new signature').evaluate().isNotEmpty);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // sheet animation
    }
    await tester.tap(find.text('Draw a new signature'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // page transition
    }

    // Draw a short zigzag and save it.
    final pad = tester.getCenter(find.byKey(const Key('signature-pad')));
    final gesture = await tester.startGesture(pad - const Offset(120, 0));
    for (var i = 1; i <= 12; i++) {
      await gesture.moveBy(Offset(20, i.isEven ? 30 : -30));
    }
    await gesture.up();
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle(() => find.byKey(const Key('signature-box')).evaluate().isNotEmpty);
    expect(find.byKey(const Key('signature-box')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));

    // Move it left and make it bigger.
    final before = tester.getRect(find.byKey(const Key('signature-box')));
    await tester.drag(find.byKey(const Key('signature-box')), const Offset(-60, 40));
    await tester.drag(find.byKey(const Key('signature-resize')), const Offset(40, 0));
    await tester.pump();
    final after = tester.getRect(find.byKey(const Key('signature-box')));
    expect(after.left, closeTo(before.left - 60, 1));
    expect(after.top, closeTo(before.top + 40, 1));
    expect(after.width, closeTo(before.width + 40, 1));

    await tester.tap(find.byKey(const Key('apply-signature')));
    await settle(() => find.textContaining('Signed and saved').evaluate().isNotEmpty);
    expect(find.textContaining('Signed and saved'), findsOneWidget);
    expect(find.byKey(const Key('signature-box')), findsNothing);

    await tester.runAsync(() async {
      final signed = await File(path).readAsBytes();
      expect(signed.length, greaterThan(original.length));
      expect(await library.versionsOf(file), hasLength(1));
      expect(await library.signatures.list(), hasLength(1));
      // The ink shows up on the page.
      final doc = await PdfDocument.openData(signed);
      final page = doc.pages.first;
      final image = (await page.render(fullWidth: 300, fullHeight: 300 * page.height / page.width, backgroundColor: 0xFFFFFFFF))!;
      var dark = 0;
      for (var i = 0; i < image.pixels.length; i += 4) {
        if (image.pixels[i] < 80 && image.pixels[i + 1] < 80 && image.pixels[i + 2] < 80) dark++;
      }
      image.dispose();
      await doc.dispose();
      // Unsigned, the page only has a few dark pixels of text.
      expect(dark, greaterThan(150));
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    dir.deleteSync(recursive: true);
  }, skip: pdfium == null);

  /// Opens [path] in the PDF reader on a phone-sized screen.
  Future<(LibraryStore, DocFile, Future<void> Function(bool Function()))> openPdf(WidgetTester tester, Directory dir, String path) async {
    Pdfrx.pdfiumModulePath = pdfium;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final library = LibraryStore(prefs, dir);
    final file = DocFile(path: path, name: path.split('/').last, sizeBytes: File(path).lengthSync(), openedAt: DateTime.now());
    await tester.pumpWidget(AppScope(
      library: library,
      settings: SettingsStore(prefs),
      child: MaterialApp(theme: AppTheme.dark(), home: PdfReaderScreen(file: file)),
    ));
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle(() => find.textContaining('Page 1 of').evaluate().isNotEmpty);
    return (library, file, settle);
  }

  testWidgets('PDF text can be highlighted and drawn on, then saved', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pdf_markup');
    final path = '${dir.path}/Notes.pdf';
    await tester.runAsync(() async {
      final doc = pw.Document()
        ..addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(50),
          build: (_) => pw.Text('Highlight this line', style: const pw.TextStyle(fontSize: 40)),
        ));
      await File(path).writeAsBytes(await doc.save());
    });
    final (library, file, settle) = await openPdf(tester, dir, path);
    await tester.tap(find.text('Annotate'));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-highlight')), findsOneWidget);
    // Give the page text a moment to load.
    await settle(() => false);

    final page = tester.getRect(find.byKey(const ValueKey('markup-layer-1')));
    Offset at(double fx, double fy) => Offset(page.left + fx * page.width, page.top + fy * page.height);
    // The text sits 50pt from the top-left corner, 40pt high.
    final lineY = (50 + 22) / PdfPageFormat.a4.height;
    final drag = await tester.startGesture(at(0.1, lineY));
    for (var i = 1; i <= 10; i++) {
      await drag.moveTo(at(0.1 + i * 0.06, lineY));
      await tester.pump();
    }
    await drag.up();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('tool-pen')));
    await tester.pump();
    final pen = await tester.startGesture(at(0.2, 0.5));
    for (var i = 1; i <= 10; i++) {
      await pen.moveTo(at(0.2 + i * 0.05, 0.5 + (i.isEven ? 0.02 : -0.02)));
      await tester.pump();
    }
    await pen.up();
    await tester.pump();

    await tester.tap(find.byKey(const Key('save-markup')));
    await settle(() => find.textContaining('Annotations saved').evaluate().isNotEmpty);
    expect(find.textContaining('Annotations saved'), findsOneWidget);
    expect(find.byKey(const ValueKey('markup-layer-1')), findsNothing);

    await tester.runAsync(() async {
      final saved = await File(path).readAsBytes();
      final text = String.fromCharCodes(saved);
      expect(text, contains('/Subtype/Highlight'));
      expect(text, contains('/Subtype/Ink'));
      expect(await library.versionsOf(file), hasLength(1));
      // The highlight covers the words, from the first letter on.
      final quad = RegExp(r'/QuadPoints\s*\[([^\]]*)\]').firstMatch(text)!.group(1)!.trim().split(RegExp(r'\s+')).map(double.parse).toList();
      final xs = [quad[0], quad[2], quad[4], quad[6]];
      final ys = [quad[1], quad[3], quad[5], quad[7]];
      expect(xs.reduce((a, b) => a < b ? a : b), closeTo(50, 6));
      expect(xs.reduce((a, b) => a > b ? a : b), greaterThan(300));
      final top = PdfPageFormat.a4.height - 50;
      expect(ys.reduce((a, b) => a > b ? a : b), closeTo(top, 10));
      expect(ys.reduce((a, b) => a < b ? a : b), closeTo(top - 40, 12));
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    dir.deleteSync(recursive: true);
  }, skip: pdfium == null);

  testWidgets('PDF forms can be filled in and saved', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pdf_form');
    final path = '${dir.path}/Form.pdf';
    File('test/fixtures/form.pdf').copySync(path);
    late List<PdfFormField> fields;
    await tester.runAsync(() async => fields = await readFormFields(await File(path).readAsBytes()));
    PdfFormField field(String name, [int i = 0]) => fields.where((f) => f.name == name).elementAt(i);
    Finder target(PdfFormField f) => find.byKey(ValueKey('field-${f.pageNumber}-${f.annotIndex}'));

    final (library, file, settle) = await openPdf(tester, dir, path);
    await tester.tap(find.text('Fill form'));
    await settle(() => find.byKey(const Key('save-form')).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(target(field('name')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(const Key('form-text')), 'Ada Lovelace');
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ada Lovelace'), findsOneWidget);

    await tester.tap(target(field('agree')));
    await tester.tap(target(field('size', 2)));
    await tester.tap(target(field('size', 1)));
    await tester.pump();

    // Locked fields say so instead of opening.
    await tester.tap(target(field('locked')));
    await tester.pump();
    expect(find.textContaining('locked'), findsOneWidget);

    await tester.tap(target(field('country')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Japan'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Japan'), findsOneWidget);
    // Undo takes back the last choice only.
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Japan'), findsNothing);
    expect(find.text('Ada Lovelace'), findsOneWidget);
    await tester.tap(target(field('country')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Germany'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.byKey(const Key('save-form')));
    await settle(() => find.textContaining('Form saved').evaluate().isNotEmpty);
    expect(find.textContaining('Form saved'), findsOneWidget);

    await tester.runAsync(() async {
      final saved = await readFormFields(await File(path).readAsBytes());
      PdfFormField get(String name, [int i = 0]) => saved.where((f) => f.name == name).elementAt(i);
      expect(get('name').value, 'Ada Lovelace');
      expect(get('agree').checked, isTrue);
      expect([for (var i = 0; i < 3; i++) get('size', i).checked], [false, true, false]);
      expect(get('country').value, 'Germany');
      expect(get('locked').value, 'fixed');
      expect(await library.versionsOf(file), hasLength(1));
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    dir.deleteSync(recursive: true);
  }, skip: pdfium == null);

  testWidgets('Excel cells can be edited, zoomed and are saved with a backup', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = Directory.systemTemp.createTempSync('xlsx_edit');
    final library = LibraryStore(prefs, dir);
    late DocFile file;
    await tester.runAsync(() async => file = await library.importBytes('Budget.xlsx', File('test/fixtures/edit.xlsx').readAsBytesSync()));
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(AppScope(
      library: library,
      settings: SettingsStore(prefs),
      child: MaterialApp(theme: AppTheme.dark(), home: OfficeReaderScreen(file: file)),
    ));
    for (var i = 0; i < 50 && find.text('Pens').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('Pens'), findsOneWidget);

    // Tap B2 to select it, tap again to type, and press Enter.
    Finder cell(String text) => find.byWidgetPredicate((w) => w is Text && w.data == text && w.style?.fontFamily == 'Calibri');
    await tester.tap(cell('10'));
    await tester.pump();
    await tester.tap(cell('10'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('formula-bar')), '20');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(cell('50'), findsOneWidget); // D2 = B2 * C2
    expect(cell('146'), findsOneWidget); // D5 = SUM(D2:D4)

    // Bold from the toolbar.
    await tester.tap(cell('Pens'));
    await tester.pump();
    await tester.tap(find.byTooltip('Bold'));
    await tester.pump();
    expect(tester.widget<Text>(cell('Pens')).style!.fontWeight, FontWeight.w700);

    // Pinch out to zoom in.
    final before = tester.getRect(cell('Pens')).width;
    final center = tester.getCenter(cell('Paper'));
    final a = await tester.startGesture(center - const Offset(30, 0));
    final b = await tester.startGesture(center + const Offset(30, 0), pointer: 7);
    for (var i = 1; i <= 5; i++) {
      await a.moveTo(center - Offset(30.0 + i * 12, 0));
      await b.moveTo(center + Offset(30.0 + i * 12, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(tester.getRect(cell('Pens')).width, greaterThan(before * 1.5));

    // Closing the reader saves, keeping the original as a backup.
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 40 && library.byPath(file.path)!.sizeBytes == file.sizeBytes; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    final saved = XlsxReader.read(File(file.path).readAsBytesSync());
    expect(saved.sheets.first.cell(1, 1)!.value, '20');
    expect(saved.sheets.first.cell(1, 0)!.style.bold, isTrue);
    final versions = (await tester.runAsync(() => library.versionsOf(file)))!;
    expect(XlsxReader.read(versions.last.readAsBytesSync()).sheets.first.cell(1, 1)!.value, '10');
    await tester.binding.setSurfaceSize(null);
    dir.deleteSync(recursive: true);
  });

  testWidgets('Word paragraphs can be typed into, split, formatted and saved', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = Directory.systemTemp.createTempSync('docx_edit');
    final library = LibraryStore(prefs, dir);
    late DocFile file;
    await tester.runAsync(() async => file = await library.importBytes('Brief.docx', File('test/fixtures/sample.docx').readAsBytesSync()));
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(AppScope(
      library: library,
      settings: SettingsStore(prefs),
      child: MaterialApp(theme: AppTheme.dark(), home: OfficeReaderScreen(file: file)),
    ));
    for (var i = 0; i < 50 && find.text('Project Brief', findRichText: true).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(find.text('Done'), findsOneWidget);

    // Tap the centred line and type at its end.
    await tester.tap(find.text('Centered line', findRichText: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('word-editor')), findsOneWidget);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '\u200BCentered line!', selection: TextSelection.collapsed(offset: 15)));
    await tester.pump();
    // Enter after "Centered".
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '\u200BCentered\n line!', selection: TextSelection.collapsed(offset: 10)));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('word-editor')));
    expect(field.controller!.text, '\u200B line!');
    // Bold the whole new paragraph.
    await tester.tap(find.byTooltip('Bold'));
    await tester.pump();

    await tester.tap(find.text('Done'));
    await tester.pump();
    for (var i = 0; i < 40 && library.byPath(file.path)!.sizeBytes == file.sizeBytes; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    final saved = DocxReader.read(File(file.path).readAsBytesSync()).blocks.whereType<DocxParagraph>().toList();
    final i = saved.indexWhere((p) => p.text == 'Centered');
    expect(i, isNonNegative);
    expect(saved[i + 1].text, ' line!');
    expect(saved[i + 1].runs.every((r) => r.bold), isTrue);
    expect(saved[i + 1].align, ParagraphAlign.center);
    expect((await tester.runAsync(() => library.versionsOf(file)))!, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    dir.deleteSync(recursive: true);
  });

  testWidgets('PowerPoint shapes can be retyped, moved and slides added', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = Directory.systemTemp.createTempSync('pptx_edit');
    final library = LibraryStore(prefs, dir);
    late DocFile file;
    await tester.runAsync(() async => file = await library.importBytes('Deck.pptx', File('test/fixtures/sample.pptx').readAsBytesSync()));
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(AppScope(
      library: library,
      settings: SettingsStore(prefs),
      child: MaterialApp(theme: AppTheme.dark(), home: OfficeReaderScreen(file: file)),
    ));
    for (var i = 0; i < 50 && find.text('Q3 Highlights', findRichText: true).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.tap(find.text('Edit'));
    await tester.pump();

    // Select the title, tap it again and retype it.
    final title = find.text('Q3 Highlights', findRichText: true);
    await tester.tap(title);
    await tester.pump();
    expect(find.byKey(const ValueKey('selected-shape')), findsOneWidget);
    await tester.tap(title);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('slide-text')), 'Q4 Highlights');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Q4 Highlights', findRichText: true), findsOneWidget);

    // Drag it down a little.
    final before = tester.getTopLeft(find.byKey(const ValueKey('selected-shape')));
    await tester.drag(find.text('Q4 Highlights', findRichText: true), const Offset(0, 40));
    await tester.pump();
    final after = tester.getTopLeft(find.byKey(const ValueKey('selected-shape')));
    expect(after.dy - before.dy, closeTo(40, 12));

    // Deselect by tapping an empty area, then add a slide after the first.
    final slide = tester.getRect(find.byKey(const ValueKey('selected-shape')));
    await tester.tapAt(Offset(slide.left + 4, slide.bottom + 30));
    await tester.pump();
    await tester.tap(find.byTooltip('New slide'));
    await tester.pump();
    expect(find.text('Tap to add title'), findsWidgets);

    await tester.tap(find.text('Done'));
    await tester.pump();
    for (var i = 0; i < 40 && library.byPath(file.path)!.sizeBytes == file.sizeBytes; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    final saved = PptxReader.read(File(file.path).readAsBytesSync());
    expect(saved.slides, hasLength(3));
    expect(saved.slides.first.title, 'Q4 Highlights');
    expect(saved.slides.first.shapes.first.rect, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    dir.deleteSync(recursive: true);
  });
}
