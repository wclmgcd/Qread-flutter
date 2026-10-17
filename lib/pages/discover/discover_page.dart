import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/routes.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/explore_category.dart';
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
/// 【分类区为什么是「流式排版」而不是两行胶囊】
/// 书源的分类项自带 `style.layout_flexBasisPercent`（占整行的百分之几）和
/// 「url 为空 = 分组标题」两个约定，官方客户端就是按这两个约定做流式布局的：
///   分组标题 basis=1  → 独占一行，当小标题用（知秋终版有 93 个，如「🔴 玄幻 🔴」）
///   普通项 basis=0.25 → 一行四个（实测 4000 个分类项里 2233 个是 0.25）
///   普通项 basis=0.4  → 一行两个到三个
/// 之前按标题里的 `·` 猜「父分类/子分类」两层 —— 那是巧合：知秋的
/// 「小说·共享章节数量」正好 basis=0.4、一行两个，看起来像"第二行"，
/// 但真正的排版依据是 style。换成 style 驱动之后，`·` 只是标题里的普通字符。
///
/// 分类项可能有上千个（知秋终版 1433 个），所以卡片限高、内部可滚动，
/// 免得书单被顶到屏幕外。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({Key? key}) : super(key: key);

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

/// 分类胶囊的行高（含行间距）。
///
/// 【为什么要固定行高】分类可能有上千个（知秋终版 1433 个 → 466 行），
/// 用 Column 一次性铺出来就是上万个 widget，切书源时会明显卡一下。
/// 固定行高之后就能用 `ListView.itemExtent`，只构建看得见的那三行。
const double _categoryRowHeight = 36;

/// 行间距
const double _categoryRowGap = 6;

/// 分类卡片最多显示几行，再多就卡片内部滚动。
///
/// 三行 ≈ 108px —— 参考图里那张卡片差不多就是这么高一截，既能看清有哪些
/// 分类，又不会把下面的书单挤出屏幕。
const int _categoryMaxRows = 3;

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

  /// 切分类 → 拉该分类的书。
  ///
  /// 不可点的项（分组标题 / 选择器）在 UI 层就不会绑 onTap，这里再挡一道：
  /// 分组标题的 url 是空串，拿去请求等于让后端拿个空地址跑书源规则。
  Future<void> _pickCategory(ExploreCategory item) async {
    final token = _token;
    if (token == null || !item.selectable) return;
    final provider = context.read<DiscoverProvider>();
    if (provider.currentCategoryUrl == item.url) return;
    await provider.setCurrentCategory(item.url);
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

    return Column(
      children: [
        if (provider.categoriesLoading)
          const LinearProgressIndicator(minHeight: 2),
        _buildCategoryCard(provider),
        const Divider(height: 1),
        Expanded(child: _buildBookList(provider)),
      ],
    );
  }

  /// 分类卡片：流式排版的胶囊，按 style 给的占比分行、分行内平分宽度。
  ///
  /// 【为什么不用 Wrap】Wrap 是按**内容宽度**排的，而书源给的占比是
  /// 「占整行的百分之几」—— 4 个 0.25 的项必须各占 1/4 行，哪怕它们的
  /// 文字只有两个字。所以这里自己算行，行内用 Expanded 按占比平分。
  Widget _buildCategoryCard(DiscoverProvider provider) {
    final cats = provider.categories;
    if (cats.isEmpty && provider.categoriesLoading) {
      // 首次进页面时分类还在路上。顶部已经有进度条了，这里不能再显示
      // 「发现页是空的」—— 那句话会先闪几秒，看着像书源坏了。
      return const SizedBox.shrink();
    }
    if (cats.isEmpty) {
      // 账号里 86 个开了发现的书源有 15 个就是这样（found 是空串）。
      // 还有一种是书源自己报错（需要登录），那个原因记在 categoriesNote 里，
      // 直接显示出来 —— 比一句「没有发现页」更能说明问题。
      return _CategoryNotice(
        text: provider.categoriesError ??
            provider.categoriesNote ??
            '该书的发现页是空的（书源没写 exploreUrl，或它自己的接口挂了）',
      );
    }

    final rows = _packCategoryRows(cats);
    final visibleRows =
        rows.length < _categoryMaxRows ? rows.length : _categoryMaxRows;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      // 高度按「实际有几行」算，别写死三行 —— 70 个源里大多数只有一两行，
      // 写死的话卡片下半截永远是空的。
      child: SizedBox(
        height: visibleRows * _categoryRowHeight,
        child: ListView.builder(
          itemExtent: _categoryRowHeight,
          physics: const ClampingScrollPhysics(),
          itemCount: rows.length,
          itemBuilder: (context, index) => _buildCategoryRow(rows[index], provider),
        ),
      ),
    );
  }

  Widget _buildCategoryRow(
      List<ExploreCategory> row, DiscoverProvider provider) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _categoryRowGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < row.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              // flex 必须是正整数，占比 ×1000 保留三位小数够用了
              flex: (row[i].safeBasis * 1000).round().clamp(1, 1000),
              child: _CategoryChip(
                label: row[i].label,
                selected: row[i].selectable &&
                    row[i].url == provider.currentCategoryUrl,
                // 分组标题（url 为空）不给 onTap —— 点了也没东西可请求，
                // 而且后端会真的拿它的标题去当 ruleFindUrl 跑规则。
                onTap: row[i].selectable ? () => _pickCategory(row[i]) : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 把分类项按 `layout_flexBasisPercent` 分行。
  ///
  /// 规则就是 flexbox 的换行算法：一行里占比累加不超过 1 就继续塞，
  /// 放不下就换行；占到正好 1（或更多）时收行。
  ///   - 分组标题 basis=1  → 独占一行
  ///   - basis=0.4 ×2     → 一行两个
  ///   - basis=0.25 ×4    → 一行四个
  ///   - 行内占比和不足 1（例如 3 个 0.29）→ 由 Expanded 平分拉满整行，
  ///     和书源里普遍写着的 `layout_flexGrow: 1` 语义一致。
  ///
  /// `layout_wrapBefore` 为真的项强制另起一行（实测有 7 处这么写）。
  List<List<ExploreCategory>> _packCategoryRows(List<ExploreCategory> cats) {
    final rows = <List<ExploreCategory>>[];
    var current = <ExploreCategory>[];
    var used = 0.0;

    void flush() {
      if (current.isNotEmpty) rows.add(current);
      current = <ExploreCategory>[];
      used = 0;
    }

    for (final c in cats) {
      if (c.wrapBefore && current.isNotEmpty) flush();
      final b = c.safeBasis;
      if (current.isNotEmpty && used + b > 1.0001) flush();
      current.add(c);
      used += b;
      if (used >= 0.9999) flush();
    }
    flush();
    return rows;
  }

  Widget _buildBookList(DiscoverProvider provider) {
    // 没有可点的分类时上面那张卡片已经把原因说清楚了，
    // 这里再补一句「这个分类下暂时没有书」只会让人更糊涂。
    if (!provider.categoriesLoading &&
        provider.selectableCategories.isEmpty) {
      return const SizedBox.shrink();
    }
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
///
/// 三种样子，靠 onTap 是否为空和 selected 区分：
///   - 可选、未选中：浅底圆角
///   - 可选、已选中：主题色淡底 + 主题色文字
///   - **不可点（onTap == null）**：就是书源自己写的分组标题
///     （「🔴 玄幻 🔴」这类），去掉底色只留文字，看起来像小标题而不是按钮 ——
///     给个"按不动"的胶囊比什么都不显示更让人困惑。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;

  /// 为空表示这一项不可点（分组标题 / 选择器控件）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    // 单行 + 省略号：行高是固定的（见 _categoryRowHeight），文字必须只占一行，
    // 否则 ListView 的 itemExtent 和实际高度对不上，会出现裁字或跳动。
    // 窄胶囊里长标题（「小说·共享章节数量」这类）会被截断，这是必然的 ——
    // 书源给的占比就那么大，想全显示只能牺牲排版一致性。
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: onTap == null
            ? theme.colorScheme.onSurfaceVariant
            : (selected ? primary : theme.colorScheme.onSurface),
        fontWeight:
            onTap == null || selected ? FontWeight.w600 : FontWeight.w500,
        fontSize: onTap == null ? 12 : 12.5,
      ),
    );

    // 不可点（分组标题）：去掉底色，看着像小标题而不是"按不动的按钮"
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Center(child: text),
      );
    }

    return Material(
      color: selected
          ? primary.withValues(alpha: 0.14)
          : theme.colorScheme.surface.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(child: text),
        ),
      ),
    );
  }
}

/// 没有分类可显示时的提示条（不该占整屏 —— 书单区域自己还有一套空态）。
class _CategoryNotice extends StatelessWidget {
  const _CategoryNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
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
