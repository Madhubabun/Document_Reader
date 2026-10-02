import 'dart:io';

import 'package:doc_reader/app_scope.dart';
import 'package:doc_reader/models/doc_file.dart';
import 'package:doc_reader/screens/create_sheet.dart';
import 'package:doc_reader/screens/images_to_pdf_screen.dart';
import 'package:doc_reader/screens/office_reader_screen.dart';
import 'package:doc_reader/screens/pdf/pdf_tool_flows.dart';
import 'package:doc_reader/screens/pdf_reader_screen.dart';
import 'package:doc_reader/services/library_store.dart';
import 'package:doc_reader/services/ooxml/docx_reader.dart';
import 'package:doc_reader/services/pdf_tools.dart';
import 'package:doc_reader/services/settings_store.dart';
import 'package:doc_reader/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Set PDFIUM_PATH to a libpdfium build to run the PDF tests.
final pdfium = Platform.environment['PDFIUM_PATH'];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('creation'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<LibraryStore> host(WidgetTester tester, Widget home) async {
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
    await tester.pumpWidget(AppScope(library: library, settings: SettingsStore(prefs), child: MaterialApp(theme: AppTheme.dark(), home: home)));
    return library;
  }

  /// Pumps, letting real async work (isolates, files) run, until [done].
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a new Word letter is created, named and opened for editing', (tester) async {
    final library = await host(tester, Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showCreateSheet(context), child: const Text('Create'))))));
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-scan')), findsOneWidget);
    expect(find.byKey(const Key('create-photos')), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-word')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('template-Letter')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-name')), 'To: the bank.docx');
    await tester.tap(find.text('OK'));
    await settle(tester, () => find.byType(OfficeReaderScreen).evaluate().isNotEmpty);
    await settle(tester, () => find.text('Done').evaluate().isNotEmpty || find.textContaining('Recipient').evaluate().isNotEmpty);

    final file = library.files.single;
    expect(file.name, 'To- the bank.docx');
    final doc = DocxReader.read(File(file.path).readAsBytesSync());
    expect(doc.blocks.whereType<DocxParagraph>().map((p) => p.text), contains('Dear Recipient,'));
    expect(tester.widget<OfficeReaderScreen>(find.byType(OfficeReaderScreen)).startEditing, isTrue);
    // Close the reader so its save timer finishes.
    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => true);
  });

  testWidgets('pictures become a PDF in the chosen order and turn', (tester) async {
    final red = Uint8List.fromList(img.encodeJpg(img.Image(width: 60, height: 40)..clear(img.ColorRgb8(255, 0, 0))));
    final blue = Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 60)..clear(img.ColorRgb8(0, 0, 255))));
    final green = Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 40)..clear(img.ColorRgb8(0, 255, 0))));
    final library = await host(tester, ImagesToPdfScreen(initial: [red, blue, green]));
    await tester.pump();
    expect(find.text('Create PDF · 3 pages'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Remove page 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove page 3'));
    await tester.pump();
    await tester.ensureVisible(find.byTooltip('Turn page 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Turn page 1'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('pdf-name')), 'Receipts.pdf');
    await tester.tap(find.text('Create PDF · 2 pages'));
    await settle(tester, () => library.files.isNotEmpty && find.byType(PdfReaderScreen).evaluate().isNotEmpty);

    final file = library.files.single;
    expect(file.name, 'Receipts.pdf');
    await tester.pumpWidget(const SizedBox());
    await settle(tester, () => true);
    // The page boxes, read from the file: the wide red picture, turned,
    // gets a portrait page.
    final boxes = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)')
        .allMatches(String.fromCharCodes(File(file.path).readAsBytesSync()))
        .map((m) => (double.parse(m[1]!), double.parse(m[2]!)))
        .toList();
    expect(boxes, hasLength(2));
    expect(boxes.first.$1, lessThan(boxes.first.$2));
  });

  test('page ranges are read the way people type them', () {
    expect(parseRanges('1-3, 5, 7-', 9), [
      [1, 2, 3],
      [5],
      [7, 8, 9],
    ]);
    expect(parseRanges(' 2 – 2 ;4', 4), [
      [2],
      [4],
    ]);
    expect(() => parseRanges('3-1', 4), throwsFormatException);
    expect(() => parseRanges('1-9', 4), throwsFormatException);
    expect(() => parseRanges('a', 4), throwsFormatException);
    expect(() => parseRanges('  ', 4), throwsFormatException);
  });

  /// A 3-page PDF in the library, open in the reader.
  Future<(LibraryStore, DocFile)> openReader(WidgetTester tester) async {
    final path = '${dir.path}/source.pdf';
    await tester.runAsync(() async {
      final doc = pw.Document();
      for (var n = 1; n <= 3; n++) {
        doc.addPage(pw.Page(pageFormat: PdfPageFormat.a5, build: (_) => pw.Text('Page $n')));
      }
      await File(path).writeAsBytes(await doc.save());
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final seeded = LibraryStore(prefs, dir);
    final file = await tester.runAsync(() => seeded.importBytes('Report.pdf', File(path).readAsBytesSync()));
    final library = await host(tester, PdfReaderScreen(file: file!));
    await tester.runAsync(() async => library.load());
    await settle(tester, () => find.textContaining('Page 1 of').evaluate().isNotEmpty);
    return (library, file);
  }

  Future<void> openMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(const Key('pdf-tools')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(item)));
    await tester.pump();
  }

  testWidgets('the reader can lock, then unlock, a PDF', (tester) async {
    final (library, file) = await openReader(tester);
    await openMenu(tester, 'menu-lock');
    await settle(tester, () => find.byKey(const Key('password')).evaluate().isNotEmpty);
    await tester.enterText(find.byKey(const Key('password')), 'secret');
    await tester.enterText(find.byKey(const Key('password-again')), 'secrex');
    await tester.tap(find.byKey(const Key('password-ok')));
    await tester.pump();
    expect(find.text('The two passwords are different.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('password-again')), 'secret');
    await tester.tap(find.byKey(const Key('password-ok')));
    await settle(tester, () => find.textContaining('Locked with AES-256').evaluate().isNotEmpty);
    expect(find.textContaining('Locked with AES-256'), findsOneWidget);
    final locked = File(file.path).readAsBytesSync();
    expect(await tester.runAsync(() => needsPassword(locked)), isTrue);
    expect(await tester.runAsync(() => library.versionsOf(file)), isEmpty);
    // The reader reopens it with the new password, without asking.
    await settle(tester, () => find.textContaining('Page 1 of 3').evaluate().isNotEmpty);
    expect(find.textContaining('Page 1 of 3'), findsOneWidget);

    await openMenu(tester, 'menu-unlock');
    await settle(tester, () => find.textContaining('Password removed').evaluate().isNotEmpty);
    expect(await tester.runAsync(() => needsPassword(File(file.path).readAsBytesSync())), isFalse);
    await tester.pumpWidget(const SizedBox());
  }, skip: pdfium == null);

  testWidgets('the reader can remove and turn pages, and split the file', (tester) async {
    final (library, file) = await openReader(tester);
    await openMenu(tester, 'menu-organize');
    await settle(tester, () => find.text('Organize pages').evaluate().isNotEmpty && find.byTooltip('Remove page 2').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Remove page 2'));
    await tester.pump();
    await tester.tap(find.byTooltip('Turn page 1'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('organize-save')));
    await settle(tester, () => find.textContaining('Pages saved').evaluate().isNotEmpty);
    await settle(tester, () => find.textContaining('Page 1 of 2').evaluate().isNotEmpty);
    expect(find.textContaining('Page 1 of 2'), findsOneWidget);
    await tester.runAsync(() async {
      final doc = await PdfDocument.openFile(file.path);
      expect(doc.pages.map((p) => p.rotation), [PdfPageRotation.clockwise90, PdfPageRotation.none]);
      expect((await doc.pages[1].loadStructuredText()).fullText, contains('Page 3'));
      await doc.dispose();
    });
    expect(await tester.runAsync(() => library.versionsOf(file)), hasLength(1));

    await openMenu(tester, 'menu-split');
    await settle(tester, () => find.byKey(const Key('split-every')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('split-every')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('split-ok')));
    await settle(tester, () => find.textContaining('Saved 2 PDFs').evaluate().isNotEmpty);
    expect(library.files.map((f) => f.name), containsAll(['Report (page 1).pdf', 'Report (page 2).pdf']));
    await tester.pumpWidget(const SizedBox());
  }, skip: pdfium == null);
}
