import 'package:shared_preferences/shared_preferences.dart';

/// 「关闭更新」开关的本地存储。
///
/// 后端 Booklist 没有 canUpdate 列，书架接口也不认这个字段，所以开关只能
/// 留在本机：书架下拉刷新、一键刷新在调 refreshBook 之前先问一下这里。
class BookUpdatePrefs {
  BookUpdatePrefs._();

  static const _prefix = 'book_update_disabled_';

  static Future<bool> isDisabled(String bookUrl) async {
    if (bookUrl.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_prefix${Uri.encodeComponent(bookUrl)}') ?? false;
  }

  static Future<void> setDisabled(String bookUrl, bool disabled) async {
    if (bookUrl.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefix${Uri.encodeComponent(bookUrl)}';
    if (disabled) {
      await prefs.setBool(key, true);
    } else {
      await prefs.remove(key);
    }
  }

  static Future<void> toggle(String bookUrl) async {
    final disabled = await isDisabled(bookUrl);
    await setDisabled(bookUrl, !disabled);
  }

  /// 当前所有「关闭更新」的书籍 URL
  static Future<Set<String>> disabledUrls() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefix) || prefs.getBool(key) != true) continue;
      out.add(Uri.decodeComponent(key.substring(_prefix.length)));
    }
    return out;
  }
}
