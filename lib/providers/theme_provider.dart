import 'package:flutter/material.dart';

import '../services/storage_service.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  bool _initialized = false;

  ThemeMode get themeMode => _themeMode;
  bool get initialized => _initialized;

  Future<void> init() async {
    final storage = await StorageService.instance;
    final savedMode = storage.themeMode;
    switch (savedMode) {
      case 1:
        _themeMode = ThemeMode.light;
        break;
      case 2:
        _themeMode = ThemeMode.dark;
        break;
      default:
        _themeMode = ThemeMode.system;
        break;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    final storage = await StorageService.instance;
    // ThemeMode 是 Flutter SDK 的枚举，不由本仓库维护：SDK 一旦新增成员，
    // 把当时已知值全列举、不写 default 的 switch 就会因「不再穷尽」直接
    // 编译失败（dio 的 transformTimeout 就是这么炸的）。故此处用 default 收口，
    // 未知/新增模式一律按 system 存 0。
    int raw;
    switch (mode) {
      case ThemeMode.light:
        raw = 1;
        break;
      case ThemeMode.dark:
        raw = 2;
        break;
      default:
        raw = 0;
        break;
    }
    await storage.setThemeMode(raw);
    notifyListeners();
  }

  Future<void> toggleLightDark() async {
    final nextMode =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await setThemeMode(nextMode);
  }

  bool isDark(BuildContext context) {
    if (_themeMode == ThemeMode.system) {
      return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    }
    return _themeMode == ThemeMode.dark;
  }
}
