import 'package:flutter/widgets.dart';

import 'services/library_store.dart';
import 'services/settings_store.dart';

/// Makes the app's stores available to the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.library, required this.settings, required super.child});

  final LibraryStore library;
  final SettingsStore settings;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => library != oldWidget.library || settings != oldWidget.settings;
}
