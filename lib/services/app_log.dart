import 'dart:collection';

/// 轻量运行日志
///
/// 阅读器「更多 → 显示日志」和书架「查看日志」用它。
/// 只放内存、只留最近 [maxEntries] 条，不做持久化 —— 目的是让用户
/// 在遇到「段评点不开 / 换源失败 / 正文加载失败」时能直接看到原因，
/// 而不是只有一个 SnackBar。
class AppLog {
  AppLog._();

  static const int maxEntries = 300;

  static final ListQueue<String> _entries = ListQueue<String>();

  static List<String> get entries => _entries.toList(growable: false);

  static bool get isEmpty => _entries.isEmpty;

  static void add(String message) {
    final now = DateTime.now();
    final ts = '${_p(now.hour)}:${_p(now.minute)}:${_p(now.second)}';
    _entries.addLast('[$ts] $message');
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
  }

  static void clear() => _entries.clear();

  static String _p(int v) => v.toString().padLeft(2, '0');
}
