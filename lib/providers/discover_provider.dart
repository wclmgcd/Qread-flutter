import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/explore_category.dart';
import '../models/search_result.dart';
import '../models/source_ui.dart';
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
  // 当前书源的分类列表（内存，不持久化）
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
  // 当前书源的自定义界面（登录 / 设置）
  // ============================================================
  List<SourceUiItem> _sourceUi = [];
  bool _sourceUiLoading = false;

  /// 书源登录信息的原文（可能是 `{"邮箱":"..."}` 这种 JSON，也可能是裸字符串）。
  String _loginInfoRaw = '';

  List<SourceUiItem> get sourceUi => _sourceUi;
  bool get sourceUiLoading => _sourceUiLoading;
  String get loginInfoRaw => _loginInfoRaw;

  /// 这个源有没有自定义登录/设置界面 —— 决定界面右上角要不要显示人像按钮。
  bool get hasSourceUi => _sourceUi.isNotEmpty;

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
    _categoriesNote = null;
    // 登录界面是跟着书源走的，换源必须清掉 —— 否则新源会短暂顶着
    // 上一个源的人像按钮，点开还是上个源的设置项
    _sourceUi = [];
    _loginInfoRaw = '';
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
    await reloadBooks(accessToken);
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
        _categories = [];
        _categoriesError = '获取发现分类失败';
        return;
      }
      final data = result['data'];
      final parsed = ExploreCategory.parse(data?['found']);
      _categories = parsed.items;
      _categoriesNote = parsed.note;
      // 顺手把书源自定义界面也拉回来（决定右上角显不显示人像按钮）。
      // 【为什么不 await】它要先跑书源里的 JS、必要时还会去访问书源站点，
      // 慢起来好几秒；分类和书单没必要等它 —— 拉到了再 notify 一次即可。
      unawaited(loadSourceUi(accessToken, sourceUrl));
    } catch (e) {
      _categoriesError = friendlyError(e);
    } finally {
      _categoriesLoading = false;
      notifyListeners();
    }
  }

  // ============================================================
  // 书源自定义界面（登录 / 设置）
  // ============================================================

  /// 拉书源自定义界面 + 当前登录信息。
  ///
  /// 拿不到（书源没写 loginUi）时就存空列表 —— 界面据此决定不显示人像按钮。
  Future<void> loadSourceUi(String accessToken, String sourceUrl) async {
    _sourceUiLoading = true;
    try {
      // 两个请求互不依赖，一起发，省一次往返
      final results = await Future.wait([
        ApiService.instance.getSourcesLoginUi(accessToken, sourceUrl),
        ApiService.instance.getLoginInfo(accessToken, sourceUrl),
      ]);
      if (_currentSourceUrl != sourceUrl) return; // 期间切了书源，结果作废
      final uiResp = results[0];
      final infoResp = results[1];
      final rawInfo = infoResp['isSuccess'] == true
          ? SourceUiItem.rawLoginInfo(infoResp['data'])
          : '';
      final loginMap = SourceUiItem.parseLoginInfo(
          infoResp['isSuccess'] == true ? infoResp['data'] : null);
      _loginInfoRaw = rawInfo;
      _sourceUi = uiResp['isSuccess'] == true
          ? SourceUiItem.parse(uiResp['data'], loginInfo: loginMap)
          : <SourceUiItem>[];
    } catch (_) {
      // 拉不到就当没有登录界面 —— 不要因为一个附加能力把整页搞成错误态
      _sourceUi = [];
      _loginInfoRaw = '';
    } finally {
      _sourceUiLoading = false;
      notifyListeners();
    }
  }

  /// 执行书源界面里某个按钮的 JS，然后刷新分类 + 书单。
  ///
  /// 【为什么执行完要重拉分类】很多按钮改的就是「发现页模式 / 频道」这类变量
  /// （知秋终版的 `setType('all')`），而分类列表是书源的 JS 拿这些变量算出来的 ——
  /// 不重拉的话，用户切了模式还看到旧分类，会以为没生效。
  Future<String?> runSourceUiAction(
    String accessToken,
    String sourceUrl,
    String action, {
    String? info,
  }) async {
    try {
      final resp = await ApiService.instance.runSourceAction(
        accessToken,
        sourceUrl,
        action,
        info: info,
      );
      if (resp['isSuccess'] == false) {
        return resp['errorMsg']?.toString() ?? '执行失败';
      }
    } catch (e) {
      return friendlyError(e);
    }
    if (_currentSourceUrl != sourceUrl) return null;
    // 登录信息可能刚被改过，一起刷新
    await loadSourceUi(accessToken, sourceUrl);
    if (_currentSourceUrl != sourceUrl) return null;
    await loadCategories(accessToken, sourceUrl);
    if (_currentSourceUrl != sourceUrl) return null;
    await reloadAfterSwitch(accessToken);
    return null;
  }

  /// 保存界面上的输入框（走 `/setVariable` 之外的表单保存其实也是 action，
  /// 这里留给"只改登录信息不跑 JS"的场景）。
  Future<String?> saveSourceLoginInfo(
      String accessToken, String sourceUrl, String info) async {
    try {
      final resp = await ApiService.instance
          .setSourceVariable(accessToken, sourceUrl, info);
      if (resp['isSuccess'] == false) {
        return resp['errorMsg']?.toString() ?? '保存失败';
      }
      await loadSourceUi(accessToken, sourceUrl);
      return null;
    } catch (e) {
      return friendlyError(e);
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
