import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/book_source.dart';
import '../services/api_service.dart';
import '../services/error_text.dart';
import '../services/local_cache_service.dart';

class SourceManageProvider extends ChangeNotifier {
  List<BookSource> _sources = [];
  bool _loading = false;
  bool _canEdit = false;
  String? _error;

  // Multi-select state
  final Set<String> _selectedIds = {};
  bool _selectMode = false;

  // Search/filter
  String _searchQuery = '';
  String _filterGroup = '';

  /// null = 不限；true = 只看已启用；false = 只看已禁用
  bool? _filterEnabledOnly;
  bool _filterExploreOnly = false;

  String get filterGroup => _filterGroup;
  String get searchQuery => _searchQuery;
  bool? get filterEnabledOnly => _filterEnabledOnly;
  bool get filterExploreOnly => _filterExploreOnly;

  List<BookSource> get sources => _sources;
  bool get loading => _loading;
  bool get canEdit => _canEdit;
  String? get error => _error;
  Set<String> get selectedIds => _selectedIds;
  bool get selectMode => _selectMode;

  int get enabledCount => _sources.where((s) => s.enabled == true).length;
  int get exploreEnabledCount => _sources.where((s) => s.enabledExplore == true).length;

  /// 本次会话里被删掉的书源 url。
  ///
  /// 删除后条目已经从 [_sources] 里摘掉了，光看 `_sources` 分不清
  /// 「被删了」和「本来就没有」，所以额外记一份。
  final Set<String> _removedSourceUrls = <String>{};

  /// 应该在「发现」页隐藏的书源 url。
  ///
  /// 【为什么需要这个收口】发现页的列表来自另一条接口，是一批**独立的
  /// BookSource 实例**，而且后端只保证 `enabledExplore == true`，不管
  /// `enabled`。所以书源管理页里点「禁用」不会反映到发现页 ——
  /// 用户看到的就是「书源管理里明明已禁用，发现页还能刷出它的内容」。
  ///
  /// 这里把「已禁用」和「已删除」两类统一暴露出去，发现页直接读这个集合
  /// 做过滤即可，不需要重新请求后端，也就没有刷新前的窗口期。
  Set<String> get discoverHiddenSourceUrls => {
        for (final s in _sources)
          if (s.enabled != true && (s.bookSourceUrl ?? '').isNotEmpty)
            s.bookSourceUrl!,
        ..._removedSourceUrls,
      };

  List<BookSource> get filteredSources {
    var list = _sources;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((s) {
        return (s.bookSourceName ?? '').toLowerCase().contains(q) ||
            (s.bookSourceUrl ?? '').toLowerCase().contains(q) ||
            (s.bookSourceGroup ?? '').toLowerCase().contains(q) ||
            (s.bookSourceComment ?? '').toLowerCase().contains(q);
      }).toList();
    }
    if (_filterGroup.isNotEmpty) {
      list = list.where((s) => s.bookSourceGroup == _filterGroup).toList();
    }
    if (_filterEnabledOnly != null) {
      final want = _filterEnabledOnly!;
      list = list.where((s) => (s.enabled == true) == want).toList();
    }
    if (_filterExploreOnly) {
      list = list.where((s) => s.enabledExplore == true).toList();
    }
    return list;
  }

  List<String> get allGroups {
    final groups = <String>{};
    for (final s in _sources) {
      final g = (s.bookSourceGroup ?? '').trim();
      if (g.isNotEmpty) groups.add(g);
    }
    final sorted = groups.toList()..sort();
    return sorted;
  }

  // ============ Search/filter ============

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setFilterGroup(String group) {
    _filterGroup = group == _filterGroup ? '' : group;
    notifyListeners();
  }

  /// 只看已启用 / 只看已禁用
  void setFilterEnabledOnly(bool onlyEnabled) {
    _filterEnabledOnly = onlyEnabled;
    notifyListeners();
  }

  void toggleFilterExploreOnly() {
    _filterExploreOnly = !_filterExploreOnly;
    notifyListeners();
  }

  /// 清掉所有筛选条件（分组 / 启用状态 / 发现）
  void clearFilters() {
    _filterGroup = '';
    _filterEnabledOnly = null;
    _filterExploreOnly = false;
    notifyListeners();
  }

  // ============ Selection ============

  void toggleSelectMode() {
    _selectMode = !_selectMode;
    if (!_selectMode) _selectedIds.clear();
    notifyListeners();
  }

  /// 勾选/取消一个书源。
  ///
  /// 【对齐 3.41】复选框是**常驻**的，底部批量栏也常驻（`全选 (0/34) 反选
  /// 删除 更多`）。所以「勾上任意一项」本身就意味着进入多选态，不需要
  /// 先点工具栏上的「批量管理」。
  void toggleSelection(String id) {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
      _selectMode = true;
    }
    notifyListeners();
  }

  void selectAll() {
    _selectedIds.clear();
    for (final s in filteredSources) {
      if (s.bookSourceUrl != null) _selectedIds.add(s.bookSourceUrl!);
    }
    notifyListeners();
  }

  /// 反选（对齐 3.41 批量栏上的「反选」）。
  ///
  /// 和 [selectAll] 一样只在**当前可见（过滤后）**的列表里翻转 ——
  /// 用户开着「只看已禁用」时点反选，期望的是把眼前这批翻过来，
  /// 而不是把看不见的那些也一起选进来。
  void invertSelection() {
    for (final s in filteredSources) {
      final id = s.bookSourceUrl;
      if (id == null) continue;
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedIds.clear();
    _selectMode = false;
    notifyListeners();
  }

  // ============ Data loading ============

  /// 本地缓存的文件名。
  ///
  /// 按 accessToken 分作用域：换账号 / 换服务器（token 必然不同）不会串数据。
  /// `scopedKey` 是 FNV-1a 摘要，出来是纯 hex，可以安全当文件名。
  String _cacheKey(String accessToken) =>
      'book_sources_${LocalCacheService.instance.scopedKey(accessToken)}';

  /// 打开书源管理时先用本地缓存把列表铺上。
  ///
  /// 【为什么需要】
  /// 之前每次进这个页面都走全量网络：`/getCanSource` + `/getBookSourcesPage`
  /// + 按 md5 逐页拉 `/getBookSourcesNew`。哪怕只改了 0 条也要等一个来回，
  /// 用户看到的就是「每次打开都要刷新一会」。而 3.41 是**本地数据库**，
  /// 打开即有 —— 这里用一份本地 JSON 快照把差距补上。
  ///
  /// 只铺内存里还是空的时候；已经有数据（比如刚在这个会话里拉过）就不覆盖，
  /// 免得把用户刚改的状态回滚成旧的。
  Future<void> _restoreFromCache(String accessToken) async {
    if (_sources.isNotEmpty) return;
    final cached =
        await LocalCacheService.instance.readJsonObject(_cacheKey(accessToken));
    if (cached == null) return;
    final raw = cached['sources'];
    if (raw is! List) return;
    final restored = <BookSource>[];
    for (final item in raw) {
      if (item is Map) {
        restored.add(BookSource.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    if (restored.isEmpty) return;
    _sources = restored;
    if (cached['canEdit'] is bool) _canEdit = cached['canEdit'] as bool;
    notifyListeners();
  }

  /// 网络拉回来之后写一份快照，下次打开就能立刻显示。
  ///
  /// 写失败不影响主流程（缓存只是加速，不是数据源），所以整个吞掉异常。
  Future<void> _saveToCache(String accessToken) async {
    try {
      await LocalCacheService.instance.saveJson(_cacheKey(accessToken), {
        'canEdit': _canEdit,
        'sources': _sources.map((s) => s.toJson()).toList(),
      });
    } catch (_) {}
  }

  Future<void> loadSources(String accessToken, {bool refresh = false}) async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();

    // 1. 先上缓存 —— 页面打开即有内容，不用等网络
    if (!refresh) {
      await _restoreFromCache(accessToken);
    }

    // 2. 再拉网络。拉回来就覆盖并刷新缓存；失败就保留缓存那份，
    //    不要把整页变成错误页（错误只在列表为空时才展示）。
    try {
      final permissionFuture = ApiService.instance.getCanSource(accessToken);
      final pageData = await ApiService.instance.getBookSourcesPage(accessToken);
      final data = pageData['data'] ?? pageData;
      final md5 = data['md5']?.toString();
      final totalPages = int.tryParse(data['page']?.toString() ?? '1') ?? 1;

      List<BookSource> allSources = [];
      if (md5 != null) {
        for (int page = 1; page <= totalPages; page++) {
          final pageSources = await ApiService.instance.getBookSourcesNew(
            accessToken,
            md5: md5,
            page: page,
          );
          if (pageSources.isEmpty) break;
          allSources.addAll(pageSources);
        }
      }
      if (allSources.isEmpty) {
        allSources = await ApiService.instance.getBookSources(accessToken);
      }

      _canEdit = await permissionFuture;
      _sources = allSources;
      // 整表重拉之后，服务端返回的就是权威结果，之前记的「已删除」
      // 不再需要（万一用户在别处又导入回来了，也不该继续被隐藏）
      _removedSourceUrls.clear();
      unawaited(_saveToCache(accessToken));
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ============ Single operations ============

  Future<bool> toggleEnabled(String accessToken, BookSource source) async {
    final id = source.bookSourceUrl;
    if (id == null) return false;
    final st = source.enabled == true ? 0 : 1;
    try {
      final result = await ApiService.instance.stopbookSource(accessToken, id, st: st);
      if (result['isSuccess'] == true) {
        source.enabled = st == 1;
        notifyListeners();
        unawaited(_saveToCache(accessToken));
        return true;
      }
      _error = result['errorMsg'] ?? '操作失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> toggleExploreEnabled(String accessToken, BookSource source) async {
    final id = source.bookSourceUrl;
    if (id == null) return false;
    try {
      Map<String, dynamic> result;
      if (source.enabledExplore == true) {
        result = await ApiService.instance.stopbookSourceExplores(accessToken, [id]);
      } else {
        result = await ApiService.instance.startbookSourceExplores(accessToken, [id]);
      }
      if (result['isSuccess'] == true) {
        source.enabledExplore = !(source.enabledExplore == true);
        notifyListeners();
        unawaited(_saveToCache(accessToken));
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteSource(String accessToken, String id) async {
    try {
      final result = await ApiService.instance.delbookSource(accessToken, id);
      if (result['isSuccess'] == true) {
        _sources.removeWhere((s) => s.bookSourceUrl == id);
        _selectedIds.remove(id);
        // 记下来，发现页据此把这条也摘掉
        _removedSourceUrls.add(id);
        notifyListeners();
        unawaited(_saveToCache(accessToken));
        return true;
      }
      _error = result['errorMsg'] ?? '删除失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> topSourceItem(String accessToken, String id) async {
    try {
      final result = await ApiService.instance.topSource(accessToken, id);
      if (result['isSuccess'] == true) {
        await loadSources(accessToken, refresh: true);
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> bottomSourceItem(String accessToken, String id) async {
    try {
      final result = await ApiService.instance.bottomSource(accessToken, id);
      if (result['isSuccess'] == true) {
        await loadSources(accessToken, refresh: true);
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  // ============ Batch operations ============

  Future<bool> batchDelete(String accessToken) async {
    if (_selectedIds.isEmpty) return false;
    try {
      final ids = _selectedIds.toList();
      final result = await ApiService.instance.delbookSources(accessToken, ids);
      if (result['isSuccess'] == true) {
        _sources.removeWhere((s) => ids.contains(s.bookSourceUrl));
        _selectedIds.clear();
        // 记下来，发现页据此把这些也摘掉
        _removedSourceUrls.addAll(ids);
        notifyListeners();
        unawaited(_saveToCache(accessToken));
        return true;
      }
      _error = result['errorMsg'] ?? '批量删除失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> batchSetEnabled(String accessToken, bool enabled) async {
    if (_selectedIds.isEmpty) return false;
    try {
      final ids = _selectedIds.toList();
      final result = enabled
          ? await ApiService.instance.startbookSources(accessToken, ids)
          : await ApiService.instance.stopbookSources(accessToken, ids);
      if (result['isSuccess'] == true) {
        for (final s in _sources) {
          if (ids.contains(s.bookSourceUrl)) s.enabled = enabled;
        }
        _selectedIds.clear();
        notifyListeners();
        unawaited(_saveToCache(accessToken));
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> batchSetExploreEnabled(String accessToken, bool enabled) async {
    if (_selectedIds.isEmpty) return false;
    try {
      final ids = _selectedIds.toList();
      final result = enabled
          ? await ApiService.instance.startbookSourceExplores(accessToken, ids)
          : await ApiService.instance.stopbookSourceExplores(accessToken, ids);
      if (result['isSuccess'] == true) {
        for (final s in _sources) {
          if (ids.contains(s.bookSourceUrl)) s.enabledExplore = enabled;
        }
        _selectedIds.clear();
        notifyListeners();
        unawaited(_saveToCache(accessToken));
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> batchTop(String accessToken) async {
    if (_selectedIds.isEmpty) return false;
    try {
      final ids = _selectedIds.toList();
      final result = await ApiService.instance.topallSource(accessToken, ids);
      if (result['isSuccess'] == true) {
        await loadSources(accessToken, refresh: true);
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> batchBottom(String accessToken) async {
    if (_selectedIds.isEmpty) return false;
    try {
      final ids = _selectedIds.toList();
      final result = await ApiService.instance.bottomallSource(accessToken, ids);
      if (result['isSuccess'] == true) {
        await loadSources(accessToken, refresh: true);
        return true;
      }
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> batchEditGroup(String accessToken, {required String st, String? group}) async {
    if (_selectedIds.isEmpty) return false;
    try {
      final ids = _selectedIds.toList();
      final result = await ApiService.instance.editsourcegroup(
        accessToken,
        st: st,
        group: group,
        ids: ids,
      );
      if (result['isSuccess'] == true) {
        await loadSources(accessToken, refresh: true);
        return true;
      }
      _error = result['errorMsg'] ?? '修改分组失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  // ============ Import / Export ============

  Future<String?> importSources(String accessToken, String jsonContent) async {
    try {
      final normalized = _normalizeImportJson(jsonContent);
      final result = await ApiService.instance.saveBookSources(accessToken, normalized);
      if (result['isSuccess'] == true) {
        await loadSources(accessToken, refresh: true);
        return result['errorMsg']?.toString();
      }
      _error = result['errorMsg']?.toString() ?? '导入失败';
      notifyListeners();
      return null;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return null;
    }
  }

  String _normalizeImportJson(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '[]';
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return jsonEncode(decoded);
      if (decoded is Map) return jsonEncode([decoded]);
    } catch (_) {}
    return text;
  }

  Future<String?> exportSelectedSources(String accessToken) async {
    if (_selectedIds.isEmpty) return null;
    try {
      final result = await ApiService.instance.getbookSourcejson(accessToken, _selectedIds.toList());
      if (result['isSuccess'] == true) {
        return result['data']?.toString();
      }
      return null;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return null;
    }
  }

  Future<Map<String, dynamic>?> getSourceDetail(String accessToken, String id) async {
    try {
      return await ApiService.instance.getbookSources(accessToken, id);
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return null;
    }
  }

  Future<bool> editSource(String accessToken, {String? id, required String json}) async {
    try {
      final result = await ApiService.instance.editbookSources(accessToken, id: id, json: json);
      if (result['isSuccess'] == true) {
        await loadSources(accessToken, refresh: true);
        return true;
      }
      _error = result['errorMsg']?.toString() ?? '编辑失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }
}
