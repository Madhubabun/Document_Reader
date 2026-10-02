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
import 'package:doc_reader/services/settings_store.dart';
import 'package:doc_reader/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
