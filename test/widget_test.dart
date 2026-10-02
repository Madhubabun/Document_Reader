import 'dart:io';

import 'package:doc_reader/main.dart';
import 'package:doc_reader/services/library_store.dart';
import 'package:doc_reader/services/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('widget_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(LibraryStore, SettingsStore)> stores() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return (LibraryStore(prefs, dir), SettingsStore(prefs));
  }

  testWidgets('empty home shows the friendly empty state and quick actions', (tester) async {
    final (library, settings) = await stores();
    await tester.pumpWidget(DocReaderApp(library: library, settings: settings));
    expect(find.text('Your docs'), findsOneWidget);
    expect(find.text('Your shelf is empty'), findsOneWidget);
    for (final label in ['Scan', 'Import', 'Convert']) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('recent files appear as cards and filters narrow them', (tester) async {
    final (library, settings) = await stores();
    await tester.runAsync(() async {
      await library.importBytes('Lease Agreement.pdf', [1]);
      await library.importBytes('Budget 2026.xlsx', [1]);
    });
    await tester.pumpWidget(DocReaderApp(library: library, settings: settings));
    expect(find.text('Lease Agreement'), findsOneWidget);
    expect(find.text('Budget 2026'), findsOneWidget);
    await tester.tap(find.text('Excel'));
    await tester.pump();
    expect(find.text('Lease Agreement'), findsNothing);
    expect(find.text('Budget 2026'), findsOneWidget);
  });

  testWidgets('tab bar switches to Convert and Settings', (tester) async {
    final (library, settings) = await stores();
    await tester.pumpWidget(DocReaderApp(library: library, settings: settings));
    await tester.tap(find.byTooltip('Convert'));
    await tester.pump();
    expect(find.text('Choose a file to convert'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    expect(find.text('Files open in Microsoft 365'), findsOneWidget);
  });

  testWidgets('light theme can be chosen in settings', (tester) async {
    final (library, settings) = await stores();
    await tester.pumpWidget(DocReaderApp(library: library, settings: settings));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.light);
  });
}
