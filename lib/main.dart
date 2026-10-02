import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_scope.dart';
import 'screens/root_shell.dart';
import 'services/library_store.dart';
import 'services/settings_store.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Sora', 'Manrope'], await rootBundle.loadString('assets/fonts/NOTICE.txt'));
  });
  final prefs = await SharedPreferences.getInstance();
  final docs = await getApplicationDocumentsDirectory();
  final library = LibraryStore(prefs, Directory(p.join(docs.path, 'Library')))..load();
  runApp(DocReaderApp(library: library, settings: SettingsStore(prefs)));
}

class DocReaderApp extends StatelessWidget {
  const DocReaderApp({super.key, required this.library, required this.settings});

  final LibraryStore library;
  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      library: library,
      settings: settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: 'Doc Reader',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.themeMode,
          home: const RootShell(),
        ),
      ),
    );
  }
}
