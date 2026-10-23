import 'package:flutter/material.dart';

/// 书籍详情 / 编辑 / 目录三个页面的统一配色（对齐轻阅时光）。
class BookDetailStyle {
  BookDetailStyle._();

  static const accent = Color(0xFF1BA6F2);
  static const accentDeep = Color(0xFF0B9CF5);
  static const accentSoft = Color(0xFFE3F3FE);
  static const danger = Color(0xFFFF5348);
  static const dangerSoft = Color(0xFFFCE8E6);
  static const chip = Color(0xFFF29B94);
  static const title = Color(0xFF111114);
  static const secondary = Color(0xFF8A8F99);
  static const sheetBg = Color(0xFFF2F3F5);
  static const outline = Color(0xFFC9CDD4);

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color card(BuildContext context) =>
      isDark(context) ? const Color(0xFF1C1F24) : Colors.white;

  static Color text(BuildContext context) =>
      isDark(context) ? const Color(0xFFF2F3F5) : title;

  static Color sub(BuildContext context) =>
      isDark(context) ? const Color(0xFF9AA0A6) : secondary;

  static Color soft(BuildContext context) => isDark(context)
      ? accent.withOpacity(0.16)
      : accentSoft;

  static Color sheet(BuildContext context) =>
      isDark(context) ? const Color(0xFF17191D) : sheetBg;

  static Color circleButton(BuildContext context) =>
      isDark(context) ? const Color(0xFF262A30) : Colors.white;

  static Color inputFill(BuildContext context) =>
      isDark(context) ? const Color(0xFF1C1F24) : const Color(0xFFF7F8FA);

  static List<Color> background(BuildContext context) => isDark(context)
      ? const [Color(0xFF15232D), Color(0xFF11171C), Color(0xFF0F1215)]
      : const [Color(0xFFC9E8FB), Color(0xFFE7F4FC), Color(0xFFF7FAFD)];
}
