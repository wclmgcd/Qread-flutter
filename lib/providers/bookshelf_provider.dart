import 'dart:async';

import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/book_group.dart';
import '../services/api_service.dart';
import '../services/app_settings.dart';
import '../services/error_text.dart';
import '../services/local_cache_service.dart';

class BookshelfProvider extends ChangeNotifier {
  BookshelfProvider({ApiService? api, LocalCacheService? cache})
      : _api = api ?? ApiService.instance,
        _cache = cache ?? LocalCacheService.instance;

  final ApiService _api;
  final LocalCacheService _cache;
  List<Book> _books = [];
  List<BookGroup> _groups = [];
  bool _loading = false;
  Completer<void>? _loadCompleter;
  bool _refreshPending = false;
  int _currentPage = 1;
  int _totalPages = 1;
  bool _hasMore = true;
  String? _error;
  String? _md5;
  String? _selectedGroup; // null = 全部

  List<Book> get books => _selectedGroup == null
      ? _books
      : _books.where((b) => _matchGroup(b, _selectedGroup!)).toList();
  List<Book> get allBooks => _books;
  List<BookGroup> get groups => _groups;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  String? get error => _error;
  String? get selectedGroup => _selectedGroup;

  bool _matchGroup(Book book, String groupName) {
    if (groupName == '未分组') {
      return book.group == null || book.group == 0;
    }
    if (groupName == '有声书') {
      return book.type == 1;
    }
    if (groupName == '漫画') {
      return book.type == 2;
    }
    // Custom group: Book.group is an int matching BookGroup.groupId
    BookGroup? targetGroup;
    for (final g in _groups) {
      if (g.groupName == groupName) {
        targetGroup = g;
        break;
      }
    }
    if (targetGroup != null) {
      return book.group == targetGroup.groupId;
    }
    return false;
  }

  void selectGroup(String? groupName) {
    _selectedGroup = groupName;
    notifyListeners();
  }

  /// 按「阅读偏好 → 书架排序」重排当前列表（不通知，由调用方决定时机）
  void _sortInPlace() {
    if (_books.length < 2) return;
    _books = AppSettings.instance.sortBooks<Book>(
      _books,
      nameOf: (b) => b.name,
      authorOf: (b) => b.author,
      readTimeOf: (b) => b.durChapterTime,
      updateTimeOf: (b) => b.lastCheckTime,
      orderOf: (b) => b.order,
    );
  }

  /// 排序方式变了以后由 UI 调用，立刻重排并刷新
  void applySort() {
    _sortInPlace();
    notifyListeners();
  }

  /// 只从本地列表里摘掉一本书（删除接口已经在别处调过了）
  ///
  /// 书籍信息页删书时用：先调 `/deleteBook`，成功后把本地这条摘掉，
  /// 避免为了刷新再拉一遍整页书架。
  void removeBookLocally(Book book) {
    final before = _books.length;
    _books = _books
        .where((b) => !(b.bookUrl == book.bookUrl && b.origin == book.origin))
        .toList();
    if (_books.length != before) notifyListeners();
  }

  String _cacheScope(String accessToken) =>
      _cache.scopedKey('${accessToken}_bookshelf');

  Future<void> loadBookshelf(String accessToken, {bool refresh = false}) async {
    final inFlight = _loadCompleter;
    if (inFlight != null) {
      if (refresh) _refreshPending = true;
      await inFlight.future;
      return;
    }
    if (!refresh && !_hasMore) return;

    final completion = Completer<void>();
    _loadCompleter = completion;
    _loading = true;
    var reload = refresh;
    try {
      do {
        _refreshPending = false;
        _error = null;
        notifyListeners();
        try {
          if (_books.isEmpty) await _loadLocalCache(accessToken);

          final page = reload ? 1 : _currentPage;
          var md5 = reload ? null : _md5;
          var totalPages = _totalPages;
          var groups = _groups;
          if (md5 == null) {
            final pageData = await _api.getBookshelfPage(accessToken);
            final data = pageData['data'] ?? pageData;
            if (data is! Map) {
              throw const FormatException('服务器未返回有效的书架分页信息');
            }
            final count = int.tryParse(data['page']?.toString() ?? '');
            if (count == null || count < 0) {
              throw const FormatException('服务器未返回有效的书架页数');
            }
            md5 = data['md5']?.toString();
            totalPages = count;
            if (md5 != null) {
              try {
                groups = await _api.getgroupNew(accessToken, md5);
              } catch (_) {}
            }
          }

          final newBooks = page > totalPages
              ? <Book>[]
              : await _api.getBookshelfNew(accessToken, md5: md5, page: page);

          // 列表和分页游标一起提交，刷新失败不能破坏已显示的书架。
          _books = page == 1 ? newBooks : [..._books, ...newBooks];
          _groups = groups;
          _md5 = md5;
          _totalPages = totalPages;
          _currentPage = page + 1;
          _hasMore = page < totalPages;
          _sortInPlace();
          await _saveLocalCache(accessToken);
        } catch (e) {
          _error = friendlyError(e);
        }
        reload = true;
      } while (_refreshPending);
    } finally {
      _loading = false;
      _loadCompleter = null;
      completion.complete();
      notifyListeners();
    }
  }

  Future<void> _loadLocalCache(String accessToken) async {
    final cache = _cache;
    final scope = _cacheScope(accessToken);
    final booksJson = await cache.readJsonList('bookshelf_books_$scope');
    final groupsJson = await cache.readJsonList('bookshelf_groups_$scope');
    if (booksJson != null && _books.isEmpty) {
      _books = booksJson
          .whereType<Map>()
          .map((e) => Book.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _sortInPlace();
      notifyListeners();
    }
    if (groupsJson != null && _groups.isEmpty) {
      _groups = groupsJson
          .whereType<Map>()
          .map((e) => BookGroup.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
    }
  }

  Future<void> _saveLocalCache(String accessToken) async {
    final cache = _cache;
    final scope = _cacheScope(accessToken);
    await cache.saveJson(
      'bookshelf_books_$scope',
      _books.map((book) => book.toJson()).toList(),
    );
    await cache.saveJson(
      'bookshelf_groups_$scope',
      _groups.map((group) => group.toJson()).toList(),
    );
  }

  Future<void> loadGroups(String accessToken) async {
    try {
      // 先获取 md5，再用 getgroupNew
      if (_md5 != null) {
        _groups = await _api.getgroupNew(accessToken, _md5!);
      } else {
        final pageData =
            await _api.getBookshelfPage(accessToken);
        final data = pageData['data'] ?? pageData;
        final md5 = data['md5']?.toString();
        if (md5 != null) {
          _groups = await _api.getgroupNew(accessToken, md5);
        } else {
          _groups = await _api.getBookGroups(accessToken);
        }
      }
      notifyListeners();
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
    }
  }

  Future<bool> addGroup(String accessToken, String name) async {
    try {
      final result = await _api.addgroup(accessToken, name);
      if (result['isSuccess'] == true) {
        await loadGroups(accessToken);
        return true;
      }
      _error = result['errorMsg'] ?? '添加分组失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteGroup(String accessToken, String name) async {
    try {
      final result = await _api.delgroup(accessToken, name);
      if (result['isSuccess'] == true) {
        _groups.removeWhere((g) => g.groupName == name);
        if (_selectedGroup == name) _selectedGroup = null;
        notifyListeners();
        return true;
      }
      _error = result['errorMsg'] ?? '删除分组失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> renameGroup(
      String accessToken, String oldname, String newname) async {
    try {
      final result =
          await _api.editgroup(accessToken, oldname, newname);
      if (result['isSuccess'] == true) {
        await loadGroups(accessToken);
        return true;
      }
      _error = result['errorMsg'] ?? '重命名分组失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> setBookGroup(
      String accessToken, String groupName, String bookUrl) async {
    try {
      final result = await _api.setgroup(
        accessToken,
        name: groupName == '全部' ? null : groupName,
        url: bookUrl,
      );
      if (result['isSuccess'] == true) {
        // Refresh bookshelf
        await loadBookshelf(accessToken, refresh: true);
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<void> deleteBooks(String accessToken, List<String> bookUrls) async {
    try {
      await _api.deleteBooks(accessToken, bookUrls);
      _books.removeWhere((b) => bookUrls.contains(b.bookUrl));
      notifyListeners();
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
    }
  }

  Future<bool> removeBook(String accessToken, Book book) async {
    try {
      final result = await _api.deleteBook(accessToken, book);
      if (result['isSuccess'] == true) {
        _books.removeWhere((b) => b.bookUrl == book.bookUrl);
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  /// Update a single book in the list (e.g., after progress save)
  void updateBook(Book updatedBook) {
    final idx = _books.indexWhere((b) => b.bookUrl == updatedBook.bookUrl);
    if (idx >= 0) {
      _books[idx] = updatedBook;
      notifyListeners();
    }
  }
}
