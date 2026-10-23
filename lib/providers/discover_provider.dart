import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/explore_category.dart';
import '../models/explore_group.dart';
import '../models/search_result.dart';
import '../services/api_service.dart';
import '../services/error_text.dart';
import '../services/local_cache_service.dart';

/// 发现页的整套状态。
///
/// 【设计变化】
/// 最早 discover_page 是个**书源列表**：列出所有「开了发现」的书源，点击进
/// 单书源 → 弹底 sheet 选分组 → 再进 explore_books_page 看这一组的书。
/// 现在主页一屏把**三级**全摆开（对齐官方客户端）：
///   一级 = 书源（顶栏胶囊，整屏左右滑切换）
///   二级 = 书源自己写的分组标题（`url` 为空、basis 为 1 的那些）
///   三级 = 具体分类（点一下换书单）
/// 少了两层跳转。代价是主页要自己维护「当前书源/分类」，这两者由本 provider
/// 持有并持久化，下次进 App 还在同一个地方。
///
/// 【书源自定义界面（登录 / 设置）为什么也放这里】它和分类是同一次书源
/// 上下文算出来的（都依赖书源变量），换源时必须一起清掉，放在一处才不会漏。
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
  // 当前书源的分类列表（内存 + 磁盘缓存：冷启动先贴磁盘再拉网络）
  // ============================================================
  List<ExploreCategory> _categories = [];
  bool _categoriesLoading = false;
  String? _categoriesError;

  /// 书源自己报的错（例如「请先登录」）。拿到分类的同时拿到，
  /// 一个分类都没有时显示它，比一句「没有发现页」有用得多。
  String? _categoriesNote;

  List<ExploreCategory> get categories => _categories;
  bool get categoriesLoading => _categoriesLoading;
  String? get categoriesError => _categoriesError;
  String? get categoriesNote => _categoriesNote;

  /// 可点的分类（url 非空）—— 分组标题和选择器都排除掉。
  List<ExploreCategory> get selectableCategories =>
      _categories.where((c) => c.selectable).toList(growable: false);

  // ============================================================
  // 二级分组（发现页的「三级结构」中间那层）
  // ============================================================

  /// 分类按分组标题切好的组 —— 懒算并缓存。
  ///
  /// 【为什么要缓存】知秋终版有 1433 个分类项，切一遍要遍历全表。这个 getter
  /// 会在 build 里被调用（每次滚动都可能重建），每次重切是纯浪费。
  /// `_categories` 一换就置空缓存（见 [loadCategories] 和 [setCurrentSource]）。
  List<ExploreGroup>? _groupsCache;

  /// 当前停在第二级的第几组。
  int _groupIndex = 0;

  List<ExploreGroup> get groups =>
      _groupsCache ??= groupExploreCategories(_categories);

  int get groupIndex {
    if (_groupIndex < 0) return 0;
    final n = groups.length;
    return n == 0 || _groupIndex >= n ? 0 : _groupIndex;
  }

  /// 当前这一组（第二级选中的那个）。
  ExploreGroup? get currentGroup {
    final g = groups;
    if (g.isEmpty) return null;
    return g[groupIndex];
  }

  /// 当前这一组的三级分类。
  List<ExploreCategory> get currentGroupItems => currentGroup?.items ?? const [];

  /// 第二级要不要显示。
  ///
  /// 只有一个分组时没必要占一行 —— 实测有书源（半夏小说、屋檐下文学网）
  /// 干脆没写分组标题，全部分类就是一整组，显示一个"全部"标签纯属噪音。
  bool get showGroups => groups.length > 1;

  /// 切到第二级的某一组。
  ///
  /// 【为什么切组要顺带换分类】三级分类是挂在组下面的，切了组却不换书单，
  /// 用户看到的就是「标题变了、书还是上一组的」。所以这里直接选中新组的
  /// 第一个可点分类，并重新拉书。
  ///
  /// 【为什么不用 await 通知界面】先把 `_groupIndex` 和 `_currentCategoryUrl`
  /// 改掉再 notify，第二级和三级的高亮会立刻跟上，书单随后到 ——
  /// 这样滑动的手感是"跟手的"，不会卡在旧内容上等网络。
  Future<void> setCurrentGroup(int index, String accessToken) async {
    final g = groups;
    if (index < 0 || index >= g.length) return;
    if (index == _groupIndex) return;
    _groupIndex = index;

    // 选中新组的第一个可点分类（不用 firstOrNull，免得为它引入 collection 包）
    for (final c in g[index].items) {
      if (c.selectable) {
        _currentCategoryUrl = c.url;
        break;
      }
    }
    notifyListeners();

    await reloadBooks(accessToken);
  }

  // ============================================================
  // 当前书源对象（登录界面判断要用它的 loginUi / loginUrl）
  // ============================================================

  /// 当前选中的书源。
  ///
  /// 【为什么要从列表里现找，而不是存一份引用】书源对象是可变的：在书源管理
  /// 里编辑过 `loginUi`、改过名字之后，列表会整体换新。存旧引用的话，
  /// 表现就是「刚在书源管理里配好登录，回发现页点人像还是老界面」。
  BookSource? get currentSource {
    final url = _currentSourceUrl;
    if (url == null) return null;
    for (final s in _exploreSources) {
      if (s.bookSourceUrl == url) return s;
    }
    return null;
  }

  /// 这个源有没有登录界面 —— 决定右上角要不要显示人像。
  ///
  /// 【为什么看书源自己的字段，而不是问后端】`loginUi` 是书源里写好的界面
  /// 描述，书源列表接口本来就带着它（知秋终版一万多个字符）。为了判断
  /// 「要不要显示一个按钮」再跑一次书源 JS 不值当 —— 那个请求要等好几秒，
  /// 按钮会迟到，用户还以为没有登录入口。
  ///
  /// 只有 `loginUrl` 没有 `loginUi` 的源走 WebView 登录，同样算「有登录界面」。
  bool get hasSourceLogin {
    final s = currentSource;
    if (s == null) return false;
    return (s.loginUi ?? '').trim().isNotEmpty ||
        (s.loginUrl ?? '').trim().isNotEmpty;
  }

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

  /// 分类的磁盘缓存键（按书源分）。
  String _categoriesCacheKey(String accessToken, String sourceUrl) =>
      'discover_categories_${_cacheScope(accessToken)}_'
      '${LocalCacheService.instance.scopedKey(sourceUrl)}';

  /// 首屏书籍的磁盘缓存键（按书源+分类分）。
  String _booksCacheKey(String accessToken, String src, String cat) =>
      'discover_books_${_cacheScope(accessToken)}_'
      '${LocalCacheService.instance.scopedKey('$src|$cat')}';

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
    _categoriesNote = null;
    // 分组是从分类切出来的，分类清了缓存也得清；组索引归零，
    // 否则换到一个只有两组的源、索引还停在第 50 组，会直接越界。
    _groupsCache = null;
    _groupIndex = 0;
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
  ///
  /// 【先贴磁盘缓存再走网络】分类和首屏书籍都只在内存里，冷启动进发现页
  /// 必转圈 —— 用户反馈「每次打开都重新连接」。现在内存为空时先从磁盘
  /// 贴上一次的缓存（秒出），网络回来后原地换新；网络失败也不清空已贴
  /// 上的内容（见 [loadCategories] / [reloadBooks] 的失败分支）。
  Future<void> reloadAfterSwitch(String accessToken) async {
    final url = _currentSourceUrl;
    if (url == null) return;
    if (_categories.isEmpty) {
      await _readCategoriesCache(accessToken, url);
      await loadCategories(accessToken, url);
    }
    // 只认**可点**的分类：分组标题（url 为空）和选择器不能当分类用，
    // 拿它们的标题去请求，后端会真的拿标题去跑书源规则，必然是空列表。
    final usable = selectableCategories;
    if (usable.isEmpty) return; // 该书源没有发现页（或书源自己报了错）
    // 当前选中的分类可能已失效（换了书源/分类列表变了）→ 回落到第一个。
    // 【为什么要有这一步】原来写的是 if (cur == null) 才回落，
    // 于是「换书源后 currentCategoryUrl 还留着上一个源的 URL」这种情况
    // 会带着一个不属于本源的地址去请求，后端只会返回空列表。
    final stillValid = usable.any((c) => c.url == _currentCategoryUrl);
    if (!stillValid) {
      await setCurrentCategory(usable.first.url);
    }
    if (_books.isEmpty) {
      await _readBooksCache(accessToken, url, _currentCategoryUrl!);
    }
    await reloadBooks(accessToken);
  }

  /// 从磁盘贴上一次的分类（内存里已有就不动）。
  Future<void> _readCategoriesCache(
      String accessToken, String sourceUrl) async {
    final raw = await LocalCacheService.instance
        .readJsonList(_categoriesCacheKey(accessToken, sourceUrl));
    if (raw == null || _categories.isNotEmpty) return;
    final items = <ExploreCategory>[];
    for (final e in raw) {
      if (e is Map) {
        items.add(ExploreCategory.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    if (items.isEmpty) return;
    _categories = items;
    _groupsCache = null;
    final n = groups.length;
    _groupIndex = n == 0 ? 0 : _groupIndex.clamp(0, n - 1);
    notifyListeners();
  }

  /// 从磁盘贴上一次的首屏书籍（内存里已有就不动）。
  Future<void> _readBooksCache(
      String accessToken, String src, String cat) async {
    final raw = await LocalCacheService.instance
        .readJsonList(_booksCacheKey(accessToken, src, cat));
    if (raw == null || _books.isNotEmpty) return;
    final items = <SearchResult>[];
    for (final e in raw) {
      if (e is Map) {
        items.add(SearchResult.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    if (items.isEmpty) return;
    _books = items;
    notifyListeners();
  }

  // ============================================================
  // 分类
  // ============================================================
  Future<void> loadCategories(String accessToken, String sourceUrl) async {
    _categoriesLoading = true;
    _categoriesError = null;
    // 换源/重拉时把上一次的备注清掉，否则上本书源「请先登录」的提示
    // 会挂在本源的卡片上，看着像误报。
    _categoriesNote = null;
    notifyListeners();
    try {
      final result = await ApiService.instance.getBookSourcesExploreUrl(
        accessToken,
        sourceUrl,
      );
      if (result['isSuccess'] != true) {
        // 已经贴着磁盘缓存时不清空 —— 一次网络抖动不该把首屏抹成报错。
        if (_categories.isEmpty) {
          _groupsCache = null;
          _groupIndex = 0;
          _categoriesError = '获取发现分类失败';
        }
        return;
      }
      final data = result['data'];
      final parsed = ExploreCategory.parse(data?['found']);
      _categories = parsed.items;
      _categoriesNote = parsed.note;
      _groupsCache = null;
      // 同一个源重载分类（下拉刷新 / 登录后刷新）时**不归零**：
      // 用户停在第 7 组，归零会让第二级突然弹回第一组，很突兀。
      // 只把索引夹回合法范围 —— 换源时是 setCurrentSource 负责归零。
      final n = groups.length;
      _groupIndex = n == 0 ? 0 : _groupIndex.clamp(0, n - 1);
      unawaited(LocalCacheService.instance.saveJson(
        _categoriesCacheKey(accessToken, sourceUrl),
        [for (final c in _categories) c.toJson()],
      ));
    } catch (e) {
      // 同上：有缓存兜底时静默，没缓存才报错。
      if (_categories.isEmpty) _categoriesError = friendlyError(e);
    } finally {
      _categoriesLoading = false;
      notifyListeners();
    }
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
      // 首屏落盘（限 60 条，够贴一屏半），下次冷启动先贴缓存再刷新。
      unawaited(LocalCacheService.instance.saveJson(
        _booksCacheKey(accessToken, src, cat),
        [for (final b in _books.take(60)) b.toJson()],
      ));
    } catch (e) {
      // 有磁盘缓存贴上时就别用报错盖掉它（见 reloadAfterSwitch 的注释）。
      if (_books.isEmpty) _booksError = friendlyError(e);
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
