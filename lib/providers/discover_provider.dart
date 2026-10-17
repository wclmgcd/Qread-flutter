import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/search_result.dart';
import '../services/api_service.dart';
import '../services/error_text.dart';
import '../services/local_cache_service.dart';

/// 发现页的整套状态。
///
/// 【设计变化】
/// 之前 discover_page 是个**书源列表**：列出所有「开了发现」的书源，点击进
/// 单书源 → 弹底 sheet 选分组 → 再进 explore_books_page。
/// 现在主页直接显示**当前书源某个分组的书籍**：少两层跳转。代价是主页
/// 依赖一个「当前选中的书源/分类」—— 这两者由本 provider 持有并持久化，
/// 下次进 App 还在同一个地方。
class DiscoverProvider extends ChangeNotifier {
  // ============================================================
  // 书源列表（= 之前的老能力，没动）
  // ============================================================
  List<BookSource> _exploreSources = [];
  bool _sourcesLoading = false;
  String? _sourcesError;

  List<BookSource> get exploreSources => _exploreSources;
  bool get sourcesLoading => _sourcesLoading;
  String? get sourcesError => _sourcesError;

  // ============================================================
  // 当前选中（书源 / 分类）
  // ============================================================
  String? _currentSourceUrl;
  String? _currentCategoryUrl;

  String? get currentSourceUrl => _currentSourceUrl;
  String? get currentCategoryUrl => _currentCategoryUrl;

  // ============================================================
  // 当前书源的分类列表（内存，不持久化）
  // ============================================================
  List<MapEntry<String, String>> _categories = [];
  bool _categoriesLoading = false;
  String? _categoriesError;

  List<MapEntry<String, String>> get categories => _categories;
  bool get categoriesLoading => _categoriesLoading;
  String? get categoriesError => _categoriesError;

  // ============================================================
  // 当前分类的书籍列表（分页累积在内存里，离开发现页不丢）
  // ============================================================
  List<SearchResult> _books = [];
  bool _booksLoading = false;
  bool _booksLoadingMore = false;
  bool _booksHasMore = true;
  int _booksPage = 1;
  String? _booksError;

  List<SearchResult> get books => _books;
  bool get booksLoading => _booksLoading;
  bool get booksLoadingMore => _booksLoadingMore;
  bool get booksHasMore => _booksHasMore;
  String? get booksError => _booksError;

  String _cacheScope(String accessToken) =>
      LocalCacheService.instance.scopedKey('${accessToken}_discover');

  // ============================================================
  // 持久化键
  // ============================================================
  static const _kSourceUrl = 'discover_current_source_url';
  static const _kCategoryUrl = 'discover_current_category_url';

  /// 应用启动后调一次，把上次选中的书源/分类读回来。
  ///
  /// 不在构造函数里 await，因为 provider 是 ChangeNotifierProvider 同步创建的。
  /// 由 main.dart 在 AppSettings.load 之后调一次。
  Future<void> loadPersisted() async {
    final p = await SharedPreferences.getInstance();
    _currentSourceUrl = _nullIfEmpty(p.getString(_kSourceUrl));
    _currentCategoryUrl = _nullIfEmpty(p.getString(_kCategoryUrl));
    notifyListeners();
  }

  static String? _nullIfEmpty(String? v) {
    if (v == null || v.isEmpty) return null;
    return v;
  }

  // ============================================================
  // 书源列表
  // ============================================================
  Future<void> loadExploreSources(String accessToken,
      {bool refresh = false}) async {
    if (_sourcesLoading) return;

    _sourcesLoading = true;
    _sourcesError = null;
    if (refresh) {
      _exploreSources = [];
    }
    notifyListeners();

    try {
      await _loadLocalCache(accessToken);

      final pageData =
          await ApiService.instance.getBookSourcesPage(accessToken);
      final data = pageData['data'] ?? pageData;
      final md5 = data['md5']?.toString();
      final totalPages = int.tryParse(data['page']?.toString() ?? '1') ?? 1;

      List<BookSource> allSources = [];

      if (md5 != null) {
        for (int page = 1; page <= totalPages; page++) {
          final sources = await ApiService.instance.getBookSourcesNew(
            accessToken,
            md5: md5,
            page: page,
          );
          if (sources.isEmpty) break;
          allSources.addAll(sources);
        }
      }

      if (allSources.isEmpty) {
        allSources = await ApiService.instance.getBookSources(accessToken);
      }

      _exploreSources = allSources
          .where((s) => s.enabled == true && s.enabledExplore == true)
          .toList();
      await _saveLocalCache(accessToken);
    } catch (e) {
      _sourcesError = friendlyError(e);
    } finally {
      _sourcesLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadLocalCache(String accessToken) async {
    final list = await LocalCacheService.instance.readJsonList(
      'discover_sources_${_cacheScope(accessToken)}',
    );
    if (list == null || _exploreSources.isNotEmpty) return;
    _exploreSources = list
        .whereType<Map>()
        .map((e) => BookSource.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    notifyListeners();
  }

  Future<void> _saveLocalCache(String accessToken) async {
    await LocalCacheService.instance.saveJson(
      'discover_sources_${_cacheScope(accessToken)}',
      _exploreSources.map((source) => source.toJson()).toList(),
    );
  }

  // ============================================================
  // 选中书源 / 分类 —— 任何一个变都顺带把书籍列表清掉
  // ============================================================
  Future<void> setCurrentSource(String? sourceUrl) async {
    if (_currentSourceUrl == sourceUrl) return;
    _currentSourceUrl = sourceUrl;
    _currentCategoryUrl = null;
    _categories = [];
    _books = [];
    _booksPage = 1;
    _booksHasMore = true;
    _booksError = null;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSourceUrl, sourceUrl ?? '');
    await p.setString(_kCategoryUrl, '');
  }

  Future<void> setCurrentCategory(String? categoryUrl) async {
    if (_currentCategoryUrl == categoryUrl) return;
    _currentCategoryUrl = categoryUrl;
    _books = [];
    _booksPage = 1;
    _booksHasMore = true;
    _booksError = null;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCategoryUrl, categoryUrl ?? '');
  }

  /// 切完书源/分类后由 UI 主动触发：拉分类 → 校正选中 → 拉书籍。
  Future<void> reloadAfterSwitch(String accessToken) async {
    final url = _currentSourceUrl;
    if (url == null) return;
    if (_categories.isEmpty) {
      await loadCategories(accessToken, url);
    }
    if (_categories.isEmpty) return; // 该书源没有发现分类
    // 当前选中的分类可能已失效（换了书源/分类列表变了）→ 回落到第一个。
    // 【为什么要有这一步】原来写的是 if (cur == null) 才回落，
    // 于是「换书源后 currentCategoryUrl 还留着上一个源的 URL」这种情况
    // 会带着一个不属于本源的地址去请求，后端只会返回空列表。
    final stillValid =
        _categories.any((c) => c.value == _currentCategoryUrl);
    if (!stillValid) {
      await setCurrentCategory(_categories.first.value);
    }
    await reloadBooks(accessToken);
  }

  // ============================================================
  // 分类
  // ============================================================
  Future<void> loadCategories(String accessToken, String sourceUrl) async {
    _categoriesLoading = true;
    _categoriesError = null;
    notifyListeners();
    try {
      final result = await ApiService.instance.getBookSourcesExploreUrl(
        accessToken,
        sourceUrl,
      );
      if (result['isSuccess'] != true) {
        _categories = [];
        _categoriesError = '获取发现分类失败';
        return;
      }
      final data = result['data'];
      _categories = _parseCategories(data?['found']);
    } catch (e) {
      _categoriesError = friendlyError(e);
    } finally {
      _categoriesLoading = false;
      notifyListeners();
    }
  }

  List<MapEntry<String, String>> _parseCategories(dynamic foundRaw) {
    if (foundRaw == null) return [];
    if (foundRaw is List) {
      return foundRaw.whereType<Map>().map((e) {
        final title = (e['title'] ?? e['name'] ?? '').toString();
        final url = (e['url'] ?? '').toString();
        return MapEntry(title, url.isNotEmpty ? url : title);
      }).toList();
    }
    final found = foundRaw.toString().trim();
    if (found.isEmpty) return [];
    return [const MapEntry('默认', '')];
  }

  // ============================================================
  // 书籍
  // ============================================================
  Future<void> reloadBooks(String accessToken) async {
    if (_booksLoading) return;
    final src = _currentSourceUrl;
    final cat = _currentCategoryUrl;
    if (src == null || cat == null) return;

    _booksLoading = true;
    _booksError = null;
    notifyListeners();
    try {
      final response = await ApiService.instance.getExplore(
        accessToken, src, cat,
        page: 1,
      );
      _books = _parseBooks(response);
      _booksPage = 2;
      _booksHasMore = _parseHasMore(response, _books.length);
    } catch (e) {
      _booksError = friendlyError(e);
    } finally {
      _booksLoading = false;
      notifyListeners();
    }
  }

  /// 加载下一页（滚动到底部触发）。
  Future<void> loadMoreBooks(String accessToken) async {
    if (_booksLoadingMore || !_booksHasMore) return;
    final src = _currentSourceUrl;
    final cat = _currentCategoryUrl;
    if (src == null || cat == null) return;

    _booksLoadingMore = true;
    notifyListeners();
    try {
      final response = await ApiService.instance.getExplore(
        accessToken, src, cat,
        page: _booksPage,
      );
      final incoming = _parseBooks(response);
      _books = _mergeBooks(_books, incoming);
      _booksPage += 1;
      _booksHasMore = _parseHasMore(response, incoming.length);
    } catch (e) {
      _booksError = friendlyError(e);
    } finally {
      _booksLoadingMore = false;
      notifyListeners();
    }
  }

  List<SearchResult> _parseBooks(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is List) {
      return _parseList(data);
    }
    if (data is Map) {
      for (final key in const ['books', 'list', 'data']) {
        final v = data[key];
        if (v is List) return _parseList(v);
      }
    }
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is List) return _parseList(decoded);
        if (decoded is Map && decoded['data'] is List) {
          return _parseList(decoded['data']);
        }
      } catch (_) {}
    }
    return [];
  }

  List<SearchResult> _parseList(List list) => list
      .whereType<Map>()
      .map((e) => SearchResult.fromJson(Map<String, dynamic>.from(e)))
      .toList();

  bool _parseHasMore(Map<String, dynamic> response, int count) {
    final data = response['data'];
    if (data is Map) {
      final next = data['next'] ?? data['hasNext'];
      if (next is bool) return next;
      if (next is num) return next != 0;
      if (next is String) return next == 'true' || next == '1';
    }
    return count > 0;
  }

  List<SearchResult> _mergeBooks(
      List<SearchResult> current, List<SearchResult> incoming) {
    final merged = <String, SearchResult>{};
    for (final item in current) {
      merged['${item.bookUrl}_${item.origin}'] = item;
    }
    for (final item in incoming) {
      merged['${item.bookUrl}_${item.origin}'] = item;
    }
    return merged.values.toList();
  }
}
