import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/routes.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/search_result.dart';
import '../../pages/bookshelf/book_info_page.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/app_settings.dart';
import '../../services/storage_service.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({Key? key, this.initialKeyword}) : super(key: key);

  /// 带着关键词进来（例如从「书籍信息」页点作者名跳过来）。
  /// 非空时页面一挂载就自动搜一次，不用用户再点一下。
  final String? initialKeyword;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  List<SearchResult> _results = [];
  bool _loadingSources = false;
  bool _searching = false;
  int _completedSources = 0;
  int _totalSources = 0;
  List<BookSource> _enabledSources = [];
  String? _sourceError;

  /// 精确搜索：只保留**书名**命中关键词的结果；
  /// 模糊搜索（默认）还会保留作者 / 简介命中的结果。
  /// 后端 `/searchBook` 没有精确搜索参数，只能在客户端过滤。
  bool _exact = false;

  /// 用户手选的书源（bookSourceUrl 集合）；null 表示「全部已启用书源」。
  Set<String>? _pickedSourceUrls;

  /// 最近一次搜索词（切换模糊/精确或改书源后自动重搜）
  String _lastKeyword = '';

  /// 搜索历史（最多 20 条）。
  /// 本地这份只是**离线兜底缓存**，权威数据在服务端（见 _loadHistory），
  /// 这样 iOS / 安卓 / 浏览器 / Windows 各端看到的是同一份历史。
  static const _kHistory = 'search_history';
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 【顺序不能换】_search 依赖 _enabledSources；不等书源加载完就搜，
      // 只会弹出「没有可用的搜索书源」。
      // 【历史也要先加载完】_pushHistory 是拿当前 _history 拼新列表再整体写回，
      // 历史还空着就搜会把本地那份历史覆盖成只剩这一个关键词。
      await _loadSources();
      await _loadHistory();
      final kw = widget.initialKeyword?.trim() ?? '';
      if (kw.isNotEmpty && mounted) {
        await _search(kw);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    final token = context.read<UserProvider>().token;
    if (token == null) return;

    setState(() {
      _loadingSources = true;
      _sourceError = null;
    });

    try {
      final pageData = await ApiService.instance.getBookSourcesPage(token);
      final data = pageData['data'] ?? pageData;
      final md5 = data['md5']?.toString();
      final totalPages = int.tryParse(data['page']?.toString() ?? '1') ?? 1;

      List<BookSource> allSources = [];
      if (md5 != null) {
        for (int p = 1; p <= totalPages; p++) {
          final sources = await ApiService.instance.getBookSourcesNew(
            token,
            md5: md5,
            page: p,
          );
          if (sources.isEmpty) break;
          allSources.addAll(sources);
        }
      }

      if (allSources.isEmpty) {
        allSources = await ApiService.instance.getBookSources(token);
      }

      if (mounted) {
        setState(() {
          _enabledSources =
              allSources.where((s) => s.enabled == true).toList();
          _loadingSources = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sourceError = '加载书源失败: $e';
          _loadingSources = false;
        });
      }
    }
  }

  /// 本次要搜索的书源
  List<BookSource> get _searchSources {
    final picked = _pickedSourceUrls;
    final pool = picked == null
        ? _enabledSources
        : _enabledSources
            .where((s) => picked.contains(s.bookSourceUrl))
            .toList();
    return pool
        .where((s) =>
            s.bookSourceUrl != null && s.bookSourceUrl!.trim().isNotEmpty)
        .toList();
  }

  // ------------------------------------------------------------ 搜索历史
  //
  // 存服务端（iOS / 安卓 / 浏览器 / Windows 共享同一份），本地留一份做离线兜底。
  // 老版本的数据（本地有、服务端还空着）会在 _loadHistory 里推上去做首次同步。
  //
  // 【token 必须在第一个 await 之前取】否则会踩
  // `use_build_context_synchronously` —— 本仓库把 warning 当 fatal。

  Future<void> _loadHistory() async {
    final token = context.read<UserProvider>().token;
    final local = await _readLocalHistory();
    if (mounted && local.isNotEmpty) setState(() => _history = local);

    if (token == null) return;
    try {
      final remote = await ApiService.instance.getSearchHistory(token);
      if (remote.isNotEmpty) {
        if (mounted) setState(() => _history = remote);
        await _writeLocalHistory(remote);
      } else if (local.isNotEmpty) {
        // 服务端空、本地有 → 首次升级，逐条推上去
        for (final kw in local) {
          try {
            await ApiService.instance.addSearchHistory(token, kw);
          } catch (_) {}
        }
      }
    } catch (_) {
      // 离线 / 服务端异常：继续用本地那份
    }
  }

  Future<void> _pushHistory(String keyword) async {
    final token = context.read<UserProvider>().token;
    final list = <String>[
      keyword,
      ..._history.where((h) => h != keyword),
    ].take(20).toList();
    if (mounted) setState(() => _history = list);
    await _writeLocalHistory(list);

    if (token == null) return;
    try {
      await ApiService.instance.addSearchHistory(token, keyword);
    } catch (_) {}
  }

  Future<void> _removeHistory(String keyword) async {
    final token = context.read<UserProvider>().token;
    final list = _history.where((h) => h != keyword).toList();
    if (mounted) setState(() => _history = list);
    await _writeLocalHistory(list);

    if (token == null) return;
    try {
      await ApiService.instance.delSearchHistory(token, keyword);
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    final token = context.read<UserProvider>().token;
    if (mounted) setState(() => _history = []);
    await _writeLocalHistory(const []);

    if (token == null) return;
    try {
      await ApiService.instance.clearSearchHistory(token);
    } catch (_) {}
  }

  Future<List<String>> _readLocalHistory() async {
    final storage = await StorageService.instance;
    final raw = storage.readString(_kHistory);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      // 历史损坏就忽略，不影响搜索
      return const [];
    }
  }

  Future<void> _writeLocalHistory(List<String> list) async {
    final storage = await StorageService.instance;
    await storage.setString(_kHistory, jsonEncode(list));
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    final token = context.read<UserProvider>().token;
    if (token == null) return;

    _lastKeyword = kw;
    _pushHistory(kw);

    // 书源还没加载好时先补一次
    if (_enabledSources.isEmpty && !_loadingSources) {
      await _loadSources();
    }

    final sources = _searchSources;
    if (sources.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可用的搜索书源，请先导入支持搜索的书源')),
        );
      }
      return;
    }

    final batchSize = AppSettings.instance.searchThreadCount.clamp(1, 32);

    setState(() {
      _searching = true;
      _results = [];
      _completedSources = 0;
      _totalSources = sources.length;
    });

    final merged = <String, SearchResult>{};

    // 分批并发，边搜边把结果推给界面（源多时用户不用干等）
    for (var i = 0; i < sources.length; i += batchSize) {
      if (!mounted) return;
      final batch = sources.skip(i).take(batchSize);
      final lists = await Future.wait(batch.map((source) async {
        try {
          return await ApiService.instance.searchBook(
            token,
            kw,
            bookSourceUrl: source.bookSourceUrl,
          );
        } catch (_) {
          return <SearchResult>[];
        }
      }));
      for (final list in lists) {
        for (final r in list) {
          final key = '${r.bookUrl}_${r.origin}';
          merged.putIfAbsent(key, () => r);
        }
      }
      if (mounted) {
        setState(() {
          _completedSources += lists.length;
          _results = _rank(merged.values.toList(), kw);
        });
      }
    }

    if (mounted) {
      setState(() => _searching = false);
    }
  }

  /// 相关度排序：书名完全命中 > 书名前缀 > 书名包含 > 作者 > 简介。
  ///
  /// 官方 3.41 的搜索结果就是「关联最强的排最上面」，
  /// 而多书源合并后默认是按源顺序拼的，完全无关的结果可能排在最前。
  List<SearchResult> _rank(List<SearchResult> list, String kw) {
    final k = kw.trim();
    int score(SearchResult r) {
      final name = (r.name ?? '').trim();
      final author = (r.author ?? '').trim();
      if (name == k) return 1000;
      if (name.startsWith(k)) return 800;
      if (name.contains(k)) return 600;
      if (author == k) return 400;
      if (author.contains(k)) return 300;
      if ((r.intro ?? '').contains(k)) return 100;
      return 0;
    }

    final filtered = _exact
        ? list.where((r) => (r.name ?? '').contains(k)).toList()
        : list;

    // Dart 的 List.sort 不是稳定排序，用原始下标做 tiebreaker 保持原顺序
    final indexed = <int, SearchResult>{};
    for (var i = 0; i < filtered.length; i++) {
      indexed[i] = filtered[i];
    }
    final keys = indexed.keys.toList()
      ..sort((i, j) {
        final d = score(indexed[j]!).compareTo(score(indexed[i]!));
        return d != 0 ? d : i.compareTo(j);
      });
    return [for (final key in keys) indexed[key]!];
  }

  void _onMenu(String value) {
    switch (value) {
      case 'fuzzy':
        setState(() => _exact = false);
        break;
      case 'exact':
        setState(() => _exact = true);
        break;
      case 'sources':
        _showSourcePicker();
        return;
    }
    // 切换搜索模式后，如果已有搜索词就立即重搜，省得用户再点一次
    if (_lastKeyword.isNotEmpty) _search(_lastKeyword);
  }

  Future<void> _showSourcePicker() async {
    if (_enabledSources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有可用的书源')),
      );
      return;
    }
    final all = _enabledSources
        .map((s) => s.bookSourceUrl ?? '')
        .where((u) => u.isNotEmpty)
        .toSet();
    final selected = Set<String>.of(_pickedSourceUrls ?? all);

    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择书源'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: ListView.builder(
              itemCount: _enabledSources.length,
              itemBuilder: (_, i) {
                final s = _enabledSources[i];
                final url = s.bookSourceUrl ?? '';
                return CheckboxListTile(
                  dense: true,
                  value: selected.contains(url),
                  title: Text(
                    s.bookSourceName ?? url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    (s.bookSourceGroup ?? '').trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: (v) => setDialogState(() {
                    if (v == true) {
                      selected.add(url);
                    } else {
                      selected.remove(url);
                    }
                  }),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDialogState(() {
                selected
                  ..clear()
                  ..addAll(all);
              }),
              child: const Text('全选'),
            ),
            TextButton(
              onPressed: () => setDialogState(selected.clear),
              child: const Text('全不选'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (picked == null) return;
    setState(() {
      // 全选等价于「不限制」，存 null 更直观
      _pickedSourceUrls = picked.length == all.length ? null : picked;
    });
    if (_lastKeyword.isNotEmpty) _search(_lastKeyword);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          // 带关键词进来时不抢焦点：键盘弹出来会盖住结果
          autofocus: (widget.initialKeyword?.trim() ?? '').isEmpty,
          decoration: const InputDecoration(
            hintText: '搜索书名或作者',
            border: InputBorder.none,
          ),
          onSubmitted: _search,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _search(_controller.text),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onSelected: _onMenu,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'fuzzy',
                checked: !_exact,
                child: const Text('模糊搜索'),
              ),
              CheckedPopupMenuItem(
                value: 'exact',
                checked: _exact,
                child: const Text('精确搜索'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'sources',
                child: Row(
                  children: [
                    Icon(Icons.list_alt, size: 20),
                    SizedBox(width: 12),
                    Text('选择书源'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loadingSources) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在加载书源...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_sourceError != null && _enabledSources.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_sourceError!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadSources, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_enabledSources.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('没有可用的搜索书源'),
            const SizedBox(height: 8),
            const Text('请确保已导入支持搜索的书源，且处于启用状态',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadSources,
              child: const Text('刷新书源'),
            ),
          ],
        ),
      );
    }

    if (_searching && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '搜索中 $_completedSources/$_totalSources ...',
              style: const TextStyle(color: Colors.grey),
            ),
            if (_totalSources > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: _totalSources > 0
                      ? _completedSources / _totalSources
                      : null,
                ),
              ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      if (_searching) {
        return const Center(
          child: Text('正在搜索…', style: TextStyle(color: Colors.grey)),
        );
      }
      if (_history.isEmpty) {
        return const Center(
          child: Text('输入关键词搜索', style: TextStyle(color: Colors.grey)),
        );
      }
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                const Text('搜索历史',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const Spacer(),
                // 对齐 3.41：历史标题右侧一个「清除」，一次清完（各端同步清）
                TextButton(
                  onPressed: _clearHistory,
                  child: const Text('清除'),
                ),
              ],
            ),
          ),
          ..._history.map(
            (h) => ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 18),
              title: Text(h),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: '删除',
                onPressed: () => _removeHistory(h),
              ),
              onTap: () {
                _controller.text = h;
                _search(h);
              },
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (_searching)
          LinearProgressIndicator(
            value: _totalSources > 0 ? _completedSources / _totalSources : null,
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _search(_lastKeyword),
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final result = _results[index];
                return _SearchResultTile(
                  result: result,
                  onAdd: () => _addToBookshelf(result),
                  onOpen: () => _openInfo(result),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 打开书籍信息页（对齐 3.41：点搜索结果先进信息页，再从那里进阅读/加入书架）
  void _openInfo(SearchResult result) {
    Navigator.pushNamed(
      context,
      AppRoutes.bookInfo,
      arguments: BookInfoPageArgs(book: _toBook(result), fromBookshelf: false),
    );
  }

  Book _toBook(SearchResult r) => Book(
        bookUrl: r.bookUrl,
        name: r.name,
        author: r.author,
        coverUrl: r.coverUrl,
        intro: r.intro,
        tocUrl: r.tocUrl,
        origin: r.origin,
        originName: r.originName,
        type: 0,
        group: 0,
      );

  Future<void> _addToBookshelf(SearchResult result) async {
    final token = context.read<UserProvider>().token;
    if (token == null) return;

    try {
      await ApiService.instance.saveBook(token, _toBook(result));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已加入书架')),
        );
        context.read<BookshelfProvider>().loadBookshelf(token, refresh: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: $e')),
        );
      }
    }
  }
}

class _SearchResultTile extends StatelessWidget {
  final SearchResult result;
  final VoidCallback onAdd;
  final VoidCallback onOpen;

  const _SearchResultTile({
    required this.result,
    required this.onAdd,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final coverUrl = result.coverUrl;
    return ListTile(
      leading: Container(
        width: 40,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(4),
        ),
        child: coverUrl != null && coverUrl.isNotEmpty
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  ApiService.instance.getCoverProxyUrl(coverUrl,
                      sourceUrl: result.origin),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.book),
                ),
              )
            : const Icon(Icons.book),
      ),
      title: Text(result.name ?? '',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${result.author ?? ''} · ${result.originName ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.add_box_outlined),
        onPressed: onAdd,
        tooltip: '加入书架',
      ),
      // 点条目进「书籍信息」页（和 3.41 一致），不再直接加入书架
      onTap: onOpen,
    );
  }
}
