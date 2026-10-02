import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Page tint used by the readers: the classic white page, warm sepia or a
/// dark "night" page.
enum PageTone { light, sepia, night }

class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  ThemeMode get themeMode => switch (_prefs.getString('themeMode')) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark, // Dark first.
      };

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString('themeMode', mode.name);
    notifyListeners();
  }

  PageTone get pageTone => PageTone.values.asNameMap()[_prefs.getString('pageTone')] ?? PageTone.light;

  Future<void> setPageTone(PageTone tone) async {
    await _prefs.setString('pageTone', tone.name);
    notifyListeners();
  }
}
