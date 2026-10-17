import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/routes.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/search_result.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/discover_provider.dart';
import '../../providers/source_manage_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/error_text.dart';
import 'widgets/explore_book_tile.dart';
import 'widgets/source_picker_sheet.dart';

/// 发现页。
///
/// 【和旧版的区别】
/// 旧版是「书源列表 → 选书源 → 选分组 → 书籍」四步；本版把前两步收成
/// 顶部一颗书源胶囊，进页面直接看到**当前书源当前分类下的书**。
/// 少了两次点击，代价是页面要自己维护「当前书源/分类」——
/// 这部分状态放在 [DiscoverProvider]，并且持久化，下次进来还在原处。
///
/// 【分类为什么有两层】
/// legado 的书源把发现分类写成 `父·子`（例如 `小说·共享章节数量`），
/// 用同一个前缀聚成一组。所以这里第一行放父分类、第二行放该父下的子项。
/// 书源没有 `·` 写法时第二行自动不出现，退化成单层，观感和旧版一致。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({Key? key}) : super(key: key);

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

/// 一层父分类 + 它名下的所有子项。
class _CategoryGroup {
  _CategoryGroup(this.parent, this.children);

  /// 父分类名（`·` 之前的部分）。
  final String parent;

  /// 原始分类项（key = 完整名，value = exploreUrl）。
  final List<MapEntry<String, String>> children;

  /// 子项在 UI 上显示的名字 —— 去掉父前缀和 `·`。
  String labelOf(MapEntry<String, String> item) {
    final full = item.key;
    if (full.startsWith('$parent·')) {
      final rest = full.substring(parent.length + 1);
      if (rest.isNotEmpty) return rest;
    }
    return full;
  }
}

class _DiscoverPageState extends State<DiscoverPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _scrollController = ScrollController();

  /// 防止 didChangeDependencies 被反复触发时并发跑初始化。
  bool _bootstrapping = false;

  /// 是否已经跑过一次完整初始化（书源列表 + 分类 + 首屏书籍）。
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  String? get _token => context.read<UserProvider>().token;

  /// 过滤掉「已在书源管理里被禁用/删除」的源。
  ///
  /// 【为什么要单独抽出来】顶部胶囊、底 sheet、build 三处都要用同一份结果，
  /// 抽成一个方法保证三边看到的是同一批源，不会出现「胶囊里有、sheet 里没有」。
  /// 注意这里用 read —— 订阅变更由 build 里的 watch 负责，回调里 watch 会抛错。
  List<BookSource> _visibleSources(List<BookSource> all) {
    final hidden =
        context.read<SourceManageProvider>().discoverHiddenSourceUrls;
    return all
        .where((s) => !hidden.contains(s.bookSourceUrl))
        .toList(growable: false);
  }

  // ============================================================
  // 初始化
  // ============================================================

  /// 拉书源列表 → 校正当前书源 → 拉分类 → 拉首屏书籍。
  ///
  /// 【为什么要「校正」而不是直接用存下来的书源】
  /// 本地存的是上次选的书源 URL，但那个源可能已经被删/被禁用/不在本账号里了。
  /// 直接拿去请求会一直空列表，用户看到的是一片空白，还以为是网络问题。
  /// 所以每次启动都拿它跟当前可用列表对一遍，不在就回落到第一个。
  Future<void> _bootstrap() async {
    if (_bootstrapping || !mounted) return;
    final token = _token;
    if (token == null) return;
    _bootstrapping = true;
    try {
      final provider = context.read<DiscoverProvider>();
      if (provider.exploreSources.isEmpty) {
        await provider.loadExploreSources(token, refresh: true);
      }
      if (!mounted) return;
      final sources = _visibleSources(provider.exploreSources);
      if (sources.isEmpty) return;

      final cur = provider.currentSourceUrl;
      if (cur == null || !sources.any((s) => s.bookSourceUrl == cur)) {
        await provider.setCurrentSource(sources.first.bookSourceUrl);
      }
      if (!mounted) return;
      await provider.reloadAfterSwitch(token);
      if (mounted) setState(() => _bootstrapped = true);
    } finally {
      _bootstrapping = false;
    }
  }

  Future<void> _refreshAll() async {
    final token = _token;
    if (token == null) return;
    final provider = context.read<DiscoverProvider>();
    await provider.reloadBooks(token);
  }

  Future<void> _loadMore() async {
    final token = _token;
    if (token == null) return;
    await context.read<DiscoverProvider>().loadMoreBooks(token);
  }

  // ============================================================
  // 用户操作
  // ============================================================

  Future<void> _pickSource() async {
    final token = _token;
    if (token == null) return;
    final provider = context.read<DiscoverProvider>();
    final sources = _visibleSources(provider.exploreSources);
    if (sources.isEmpty) return;

    final picked = await showSourcePickerSheet(
      context,
      sources: sources,
      currentUrl: provider.currentSourceUrl,
    );
    if (!mounted || picked == null) return;
    if (picked.bookSourceUrl == provider.currentSourceUrl) return;

    await provider.setCurrentSource(picked.bookSourceUrl);
    if (!mounted) return;
    await provider.reloadAfterSwitch(token);
  }

  /// 切父分类 → 落到它名下第一个子项。
  Future<void> _pickParent(_CategoryGroup group) async {
    final token = _token;
    if (token == null || group.children.isEmpty) return;
    final provider = context.read<DiscoverProvider>();
    final target = group.children.first.value;
    if (provider.currentCategoryUrl == target) return;
    await provider.setCurrentCategory(target);
    if (!mounted) return;
    await provider.reloadBooks(token);
  }

  Future<void> _pickChild(MapEntry<String, String> item) async {
    final token = _token;
    if (token == null) return;
    final provider = context.read<DiscoverProvider>();
    if (provider.currentCategoryUrl == item.value) return;
    await provider.setCurrentCategory(item.value);
    if (!mounted) return;
    await provider.reloadBooks(token);
  }

  /// 点一本书 → 底 sheet（简介 + 加入书架）。
  void _showBookActions(SearchResult result) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _BookSheet(
        result: result,
        sourceName: _currentSourceName(),
        onAdd: () => _addToBookshelf(result),
      ),
    );
  }

  String? _currentSourceName() {
    final provider = context.read<DiscoverProvider>();
    for (final s in provider.exploreSources) {
      if (s.bookSourceUrl == provider.currentSourceUrl) {
        return s.bookSourceName;
      }
    }
    return null;
  }

  Future<void> _addToBookshelf(SearchResult result) async {
    final token = _token;
    if (token == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final bookshelf = context.read<BookshelfProvider>();
    try {
      final resp = await ApiService.instance.saveBook(
        token,
        Book(
          bookUrl: result.bookUrl,
          name: result.name,
          author: result.author,
          coverUrl: result.coverUrl,
          intro: result.intro,
          tocUrl: result.tocUrl,
          origin: result.origin,
          originName: result.originName,
          type: 0,
          group: 0,
        ),
      );
      if (!mounted) return;
      if (resp['isSuccess'] == false) {
        messenger.showSnackBar(
          SnackBar(content: Text('加入书架失败：${resp['errorMsg'] ?? '未知错误'}')),
        );
        return;
      }
      await bookshelf.loadBookshelf(token, refresh: true);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('已加入书架：${result.name ?? ''}')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('加入书架失败：${friendlyError(e)}')));
    }
  }

  // ============================================================
  // 分类分组
  // ============================================================

  List<_CategoryGroup> _groupCategories(
      List<MapEntry<String, String>> cats) {
    final map = <String, List<MapEntry<String, String>>>{};
    for (final c in cats) {
      final parts = c.key.split('·');
      final parent = parts.first.trim();
      map.putIfAbsent(parent.isEmpty ? c.key : parent, () => []).add(c);
    }
    return map.entries
        .map((e) => _CategoryGroup(e.key, e.value))
        .toList(growable: false);
  }

  // ============================================================
  // 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loggedIn = context.watch<UserProvider>().isLoggedIn;

    // 【为什么初始化放在 build 里而不是 didChangeDependencies】
    // didChangeDependencies 只有在「注册过依赖」的前提下才会因 provider 变化
    // 而重跑，而登出/切账号正是要靠这个时机重置 _bootstrapped。build 里已经
    // watch 了 UserProvider，放这里最可靠。addPostFrameCallback 是必须的 ——
    // _bootstrap 会调用 notifyListeners，在 build 阶段触发重建会直接报错。
    if (!loggedIn) {
      _bootstrapped = false;
    } else if (!_bootstrapped && !_bootstrapping) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    }

    final provider = context.watch<DiscoverProvider>();
    // 订阅书源禁用状态：在书源管理里点「禁用」，本页要立刻把那条过滤掉
    // （不订阅的话得等下次刷新才消失，用户会以为禁用没生效）。
    context.watch<SourceManageProvider>();
    final sources = _visibleSources(provider.exploreSources);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        titleSpacing: 4,
        leadingWidth: 56,
        leading: Center(
          child: IconButton(
            tooltip: '搜索',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.search),
            icon: const Icon(Icons.search),
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.6),
              minimumSize: const Size(40, 40),
            ),
          ),
        ),
        title: _buildSourcePill(sources),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: provider.booksLoading ? null : _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildBody(loggedIn, provider, sources),
    );
  }

  /// 顶部那颗书源胶囊：logo + 名字 + ▼。
  Widget _buildSourcePill(List<BookSource> sources) {
    final theme = Theme.of(context);
    final name = _currentSourceName() ?? '选择书源';
    final accent = sourceAccentColor(name);
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: sources.isEmpty ? null : _pickSource,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text(
                    name.isEmpty ? '源' : name.characters.first,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.arrow_drop_down,
                    color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
      bool loggedIn, DiscoverProvider provider, List<BookSource> sources) {
    if (!loggedIn) {
      return _CenterHint(
        icon: Icons.lock_outline,
        text: '登录后即可浏览书源的发现页',
        actionText: '去登录',
        onAction: () => Navigator.pushNamed(context, AppRoutes.login),
      );
    }
    if (sources.isEmpty && provider.sourcesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (sources.isEmpty) {
      return _CenterHint(
        icon: Icons.explore_off_rounded,
        text: provider.sourcesError ?? '还没有开启「发现」的书源\n去书源管理里开一个吧',
        actionText: '书源管理',
        onAction: () => Navigator.pushNamed(context, AppRoutes.sourceManage),
      );
    }

    final groups = _groupCategories(provider.categories);
    final currentGroup = _groupOf(groups, provider.currentCategoryUrl) ??
        (groups.isEmpty ? null : groups.first);

    return Column(
      children: [
        if (provider.categoriesLoading)
          const LinearProgressIndicator(minHeight: 2),
        _buildParentBar(groups, currentGroup),
        if (currentGroup != null && _needsChildBar(currentGroup))
          _buildChildBar(currentGroup, provider.currentCategoryUrl),
        const Divider(height: 1),
        Expanded(child: _buildBookList(provider)),
      ],
    );
  }

  _CategoryGroup? _groupOf(
      List<_CategoryGroup> groups, String? categoryUrl) {
    if (categoryUrl == null) return null;
    for (final g in groups) {
      if (g.children.any((c) => c.value == categoryUrl)) return g;
    }
    return null;
  }

  /// 什么时候需要第二行：这个父分类下有多个子项，或者唯一的子项名字
  /// 和父名不同（`小说·共享章节数量` 这种）。
  bool _needsChildBar(_CategoryGroup group) {
    if (group.children.length > 1) return true;
    if (group.children.isEmpty) return false;
    return group.children.first.key != group.parent;
  }

  Widget _buildParentBar(List<_CategoryGroup> groups, _CategoryGroup? current) {
    if (groups.isEmpty) return const SizedBox(height: 4);
    return Container(
      height: 46,
      alignment: Alignment.centerLeft,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final g = groups[i];
          return _CategoryChip(
            label: g.parent,
            selected: g.parent == current?.parent,
            onTap: () => _pickParent(g),
          );
        },
      ),
    );
  }

  Widget _buildChildBar(_CategoryGroup group, String? currentUrl) {
    return Container(
      height: 42,
      alignment: Alignment.centerLeft,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: group.children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final item = group.children[i];
          return _CategoryChip(
            label: group.labelOf(item),
            selected: item.value == currentUrl,
            dense: true,
            onTap: () => _pickChild(item),
          );
        },
      ),
    );
  }

  Widget _buildBookList(DiscoverProvider provider) {
    if (provider.booksLoading && provider.books.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.booksError != null && provider.books.isEmpty) {
      return _CenterHint(
        icon: Icons.error_outline,
        text: provider.booksError!,
        actionText: '重试',
        onAction: _refreshAll,
      );
    }
    if (provider.books.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 140),
            Center(child: Text('这个分类下暂时没有书')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 16),
        itemCount: provider.books.length + (provider.booksHasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= provider.books.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final book = provider.books[index];
          return ExploreBookTile(
            book: book,
            sourceName: _currentSourceName(),
            onTap: () => _showBookActions(book),
          );
        },
      ),
    );
  }
}

/// 分类胶囊。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Material(
      color: selected
          ? primary.withValues(alpha: 0.14)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 14 : 16,
            vertical: dense ? 6 : 8,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? primary : theme.colorScheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              fontSize: dense ? 13 : 14,
            ),
          ),
        ),
      ),
    );
  }
}

/// 书籍操作底 sheet。
class _BookSheet extends StatelessWidget {
  const _BookSheet({
    required this.result,
    required this.sourceName,
    required this.onAdd,
  });

  final SearchResult result;
  final String? sourceName;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final intro = result.intro ?? '';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.name ?? '未命名书籍',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '${result.author ?? '未知作者'}  ·  ${result.originName ?? sourceName ?? ''}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if ((result.latestChapterTitle ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('最新：${result.latestChapterTitle}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (intro.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Text(intro,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(height: 1.6)),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  onAdd();
                },
                icon: const Icon(Icons.add),
                label: const Text('加入书架'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 居中的空态/错误提示。
class _CenterHint extends StatelessWidget {
  const _CenterHint({
    required this.icon,
    required this.text,
    this.actionText,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionText;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (actionText != null && onAction != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(onPressed: onAction, child: Text(actionText!)),
            ],
          ],
        ),
      ),
    );
  }
}
