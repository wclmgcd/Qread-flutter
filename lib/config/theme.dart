import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  /// 浅色主题下底部导航栏 / 系统手势条的底色。
  static const Color lightNavBarColor = Colors.white;

  /// 深色主题下底部导航栏 / 系统手势条的底色。
  static const Color darkNavBarColor = Color(0xFF1E1E1E);

  /// 系统栏样式（浅色）。
  ///
  /// 【为什么必须显式指定】`AppBar` 默认会套用 `SystemUiOverlayStyle.light`
  /// 或 `.dark`，而这两个内置常量里 `systemNavigationBarColor` 是**黑色** ——
  /// 于是底部导航栏下面那条系统手势条会被涂成黑的，看起来就是
  /// 「App 最下面没铺满屏幕」。这里把它改成和底部导航栏同色即可。
  static const SystemUiOverlayStyle lightOverlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark, // Android
    statusBarBrightness: Brightness.light, // iOS
    systemNavigationBarColor: lightNavBarColor,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  );

  /// 系统栏样式（深色）。
  static const SystemUiOverlayStyle darkOverlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: darkNavBarColor,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
  );

  static ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    primarySwatch: Colors.teal,
    primaryColor: const Color(0xFF009688),
    scaffoldBackgroundColor: const Color(0xFFF5F5F5),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      centerTitle: true,
      backgroundColor: Colors.white,
      foregroundColor: Colors.black87,
      titleTextStyle: TextStyle(
        color: Colors.black87,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      systemOverlayStyle: lightOverlayStyle,
    ),
    cardTheme: CardThemeData(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Color(0xFF009688),
      unselectedItemColor: Colors.grey,
      // 显式定色，才能和上面的 systemNavigationBarColor 完全一致
      backgroundColor: lightNavBarColor,
    ),
  );

  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    primarySwatch: Colors.teal,
    primaryColor: const Color(0xFF009688),
    scaffoldBackgroundColor: const Color(0xFF121212),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      centerTitle: true,
      backgroundColor: Color(0xFF1E1E1E),
      foregroundColor: Colors.white,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      systemOverlayStyle: darkOverlayStyle,
    ),
    cardTheme: CardThemeData(
      elevation: 1,
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Color(0xFF009688),
      unselectedItemColor: Colors.grey,
      backgroundColor: darkNavBarColor,
    ),
  );
}
