import 'dart:convert';

import '../models/book.dart';
import 'api_service.dart';
import 'storage_service.dart';

/// 「我的 → 浏览历史」。
///
/// 【同步模型】服务端为准 + 本地缓存兜底：
///   - 读：优先拉服务端（iOS / 安卓 / 浏览器 / Windows 看到的是同一份），
///     网络失败退回本地缓存 —— 不要因为同步失败让用户连历史都看不到。
///   - 写：先写本地（立刻生效、离线可用），再推服务端。
///
/// 服务端按 `userid + bookUrl` 去重，所以「重复打开同一本书」只会刷新时间戳，
/// 不会越堆越多。
///
/// 记录的内容包括**不在书架里的书**（从搜索 / 发现点进去读的）—— 只要打开过
/// 阅读页就会记一条，这正是「浏览历史」和「书架」的区别。
class BrowsingHistoryService {
  static BrowsingHistoryService? _instance;
  static BrowsingHistoryService get instance =>
      _instance ??= BrowsingHistoryService._();

  static const _keyHistory = 'profile_browsing_history_books';
  static const _maxItems = 30;

  BrowsingHistoryService._();

  /// 读历史。传了 [accessToken] 就优先用服务端。
  Future<List<Book>> loadHistory({String? accessToken}) async {
    final local = await _loadLocal();
    if (accessToken == null || accessToken.isEmpty) return local;

    try {
      final remote = await ApiService.instance.getBrowsingHistory(accessToken);
      if (remote.isNotEmpty) {
        final books = _decode(remote);
        if (books.isNotEmpty) {
          // 服务端有就用服务端的，并覆盖本地缓存
          await _saveLocal(books);
          return books;
        }
      }
      // 服务端空、本地却有 —— 老版本升级上来的数据，推上去做首次同步。
      if (local.isNotEmpty) {
        try {
          await ApiService.instance.pushBrowsingHistory(
            accessToken,
            local.map((b) => jsonEncode(b.toJson())).toList(growable: false),
          );
        } catch (_) {}
      }
      return local;
    } catch (_) {
      // 离线 / 服务端异常：退回本地缓存
      return local;
    }
  }

  /// 记录「打开过这本书」。
  Future<void> recordBook(String? accessToken, Book book) async {
    final sanitized = _sanitizeBook(book);

    final history = await _loadLocal();
    history.removeWhere((item) => item.bookUrl == sanitized.bookUrl);
    history.insert(0, sanitized);
    if (history.length > _maxItems) {
      history.removeRange(_maxItems, history.length);
    }
    await _saveLocal(history);

    if (accessToken == null || accessToken.isEmpty) return;
    try {
      await ApiService.instance
          .addBrowsingHistory(accessToken, jsonEncode(sanitized.toJson()));
    } catch (_) {
      // 同步失败不打扰用户：下次打开列表还会再拉一次服务端
    }
  }

  /// 删掉一条。
  Future<void> removeBook(String? accessToken, String bookUrl) async {
    final history = await _loadLocal();
    history.removeWhere((item) => item.bookUrl == bookUrl);
    await _saveLocal(history);

    if (accessToken == null || accessToken.isEmpty) return;
    try {
      await ApiService.instance.delBrowsingHistory(accessToken, bookUrl);
    } catch (_) {}
  }

  /// 清空。
  Future<void> clearHistory(String? accessToken) async {
    await _saveLocal(const []);
    if (accessToken == null || accessToken.isEmpty) return;
    try {
      await ApiService.instance.clearBrowsingHistory(accessToken);
    } catch (_) {}
  }

  // -------------------------------------------------------------- 本地缓存

  Future<List<Book>> _loadLocal() async {
    final storage = await StorageService.instance;
    final raw = storage.readString(_keyHistory);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((item) => Book.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveLocal(List<Book> history) async {
    final storage = await StorageService.instance;
    await storage.setString(
      _keyHistory,
      jsonEncode(history.map((item) => item.toJson()).toList()),
    );
  }

  /// 把服务端返回的 JSON 串列表解成 Book；坏数据跳过，不影响其它条目。
  List<Book> _decode(List<String> jsons) {
    final out = <Book>[];
    for (final json in jsons) {
      try {
        out.add(Book.fromJson(Map<String, dynamic>.from(jsonDecode(json) as Map)));
      } catch (_) {}
    }
    return out;
  }

  Book _sanitizeBook(Book book) {
    return Book(
      bookUrl: book.bookUrl,
      name: book.name,
      author: book.author,
      coverUrl: book.coverUrl,
      customCoverUrl: book.customCoverUrl,
      tocUrl: book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      intro: book.intro,
      type: book.type,
      totalChapterNum: book.totalChapterNum,
      latestChapterTitle: book.latestChapterTitle,
      latestChapterTime: book.latestChapterTime,
      lastCheckTime: book.lastCheckTime,
    );
  }
}
