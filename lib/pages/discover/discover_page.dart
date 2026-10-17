import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/routes.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/explore_category.dart';
import '../../models/explore_group.dart';
import '../../models/flex_rows.dart';
import '../../models/search_result.dart';
import '../../providers/discover_provider.dart';
import '../../providers/source_manage_provider.dart';
import '../../providers/user_provider.dart';
import '../bookshelf/book_info_page.dart';
import '../login/source_login_page.dart';
import '../login/webview_login_page.dart';
import '../search/search_page.dart';
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

/// 一行分类的行高。
///
/// 【为什么要固定行高】分类可能有上千个（知秋终版 1433 个 → 466 行），
/// 用 Column 一次性铺出来就是上万个 widget，切书源时会明显卡一下。
/// 固定行高之后就能用 `ListView.itemExtent`，只构建看得见的那三行。
///
/// 36 = 文字 18 + 上下各 9 的呼吸空间。改小会让三行挤在一起，
/// 改大则书单被往下推 —— 参考客户端那张卡片差不多就是这么高一截。
const double _categoryRowHeight = 36;

/// 分类卡片最多显示几行，再多就卡片内部滚动。
///
/// 三行 ≈ 108px —— 参考图里那张卡片差不多就是这么高一截，既能看清有哪些
/// 分类，又不会把下面的书单挤出屏幕。
const int _categoryMaxRows = 3;

/// 第二级（分组标题）那一条的高度。
///
/// 38 ≈ 标题文字 20 + 上下留白。再高就把书单往下挤了，再矮点击区不够。
const double _groupBarHeight = 38;

/// 第二级每屏露出几个组。
///
/// 1.0 = 整行只显示当前组、居中，不露邻组 —— 和「轻阅时光」Windows 版一致。
/// 之前用 0.74 让左右各露半个邻组（像卡片轮播），和官方观感对不上。
const double _groupViewportFraction = 1.0;

class _DiscoverPageState extends State<DiscoverPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _scrollController = ScrollController();

  /// 第二级分组标题的翻页控制器。
  ///
  /// 【为什么换源时要重建它】`PageController` 的初始页只在创建时生效，
  /// 换源后 `provider.groupIndex` 归零、但 controller 还停在第 N 页 ——
  /// 表现就是"顶栏显示大灰狼，第二级还停在知秋的第 7 组"。
  /// 重建一个干净的 controller 比 jumpToPage 可靠：换源瞬间分类还没回来，
  /// PageView 的 itemCount 是 0，这时候 jump 会直接被丢掉。
  PageController _groupPageController =
      PageController(viewportFraction: _groupViewportFraction);

  /// 上次构建时用的书源 URL —— 用来发现「换源了」，好重建上面的 controller。
  String? _groupBarSourceUrl;

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
    _groupPageController.dispose();
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

  /// 点一本书 → 书籍信息页。
  ///
  /// 【为什么不再弹底 sheet】原来弹的是「简介 + 加入书架」，但这本书还能
  /// 换书源、看目录、清除缓存、加书架、直接读 —— 这些能力在书籍信息页里已经
  /// 全有了（`BookInfoPage` 本来就带 `fromBookshelf: false` 这条分支，
  /// 专给搜索页/发现页这种"还没进书架"的场景用，底部左键是「加入书架」）。
  /// 再弹一个半残的 sheet 等于让用户走一半路又得退出来。
  void _openBook(SearchResult result) {
    Navigator.pushNamed(
      context,
      AppRoutes.bookInfo,
      arguments: BookInfoPageArgs(book: _toBook(result), fromBookshelf: false),
    );
  }

  /// 书源返回的书 → 书籍信息页要的 Book。
  Book _toBook(SearchResult r) => Book(
        bookUrl: r.bookUrl,
        name: r.name,
        author: r.author,
        coverUrl: r.coverUrl,
        intro: r.intro,
        kind: r.kind,
        latestChapterTitle: r.latestChapterTitle,
        tocUrl: r.tocUrl,
        origin: r.origin,
        originName: r.originName,
        wordCount: r.wordCount,
        type: 0,
        group: 0,
      );

  /// 右上角人像 → 书源登录。
  ///
  /// 【为什么直接跳 `SourceLoginPage` 而不是自己画一套】书源的登录界面
  /// （`loginUi`）是书源自己写的一段 JS 描述：里面有输入框、按钮、跳转，
  /// 检测结果还要靠 WebSocket 从后端推回来。这套东西
  /// `SourceLoginPage` 已经全部实现了（动作执行、cookie 同步、结果回推），
  /// 而且「书源管理 → 三个横点 → 登录」走的就是它。
  /// 发现页再画一份，两边行为必然会分叉 —— 用户在发现页登完，
  /// 到书源管理里看还是没登录，这种 bug 最难查。
  ///
  /// 【怎么判断这个源有没有登录界面】直接看书源自己的字段（`loginUi` /
  /// `loginUrl`），书源列表接口本来就带着它们，不用再问后端要一遍。
  Future<void> _openSourceLogin() async {
    final provider = context.read<DiscoverProvider>();
    final source = provider.currentSource;
    if (source == null) return;

    final loginUi = (source.loginUi ?? '').trim();
    final loginUrl = (source.loginUrl ?? '').trim();

    if (loginUi.isNotEmpty) {
      await Navigator.pushNamed(
        context,
        AppRoutes.sourceLogin,
        arguments: SourceLoginPageArgs(
          sourceUrl: source.bookSourceUrl ?? '',
          sourceName: source.bookSourceName ?? '书源',
          type: 'bookSource',
          loginUi: source.loginUi,
          loginUrl: source.loginUrl,
          variableComment: source.variableComment,
          header: source.header,
        ),
      );
    } else if (loginUrl.isNotEmpty) {
      await Navigator.pushNamed(
        context,
        AppRoutes.sourceWebLogin,
        arguments: WebViewLoginPageArgs(
          sourceUrl: source.bookSourceUrl ?? '',
          sourceName: source.bookSourceName ?? '书源',
          type: 'bookSource',
          loginUrl: loginUrl,
          headers: const {},
        ),
      );
    } else {
      return;
    }

    if (!mounted) return;
    // 登录页回来：书源刚拿到 cookie，**分类要重拉** —— 很多源（知秋就是）
    // 登录后会多出「我的 / 我的书架」这类分组，不重拉就永远看不到。
    // reloadAfterSwitch 只在分类为空时才拉，所以这里先显式拉一次。
    final token = _token;
    final url = provider.currentSourceUrl;
    if (token != null && url != null) {
      await provider.loadCategories(token, url);
    }
    if (!mounted) return;
    if (token != null) await provider.reloadAfterSwitch(token);
  }

  /// 搜索 —— 范围锁在**当前书源**。
  ///
  /// 【为什么不走 `AppRoutes.search`】那条路由注册的是 `const SearchPage()`，
  /// 塞不进参数。而"搜当前书源"恰恰要靠参数表达，所以这里直接构造。
  ///
  /// 【为什么要限定范围】书源胶囊本身就在说"我现在在看知秋终版"，
  /// 在这个上下文里点搜索，用户预期就是「在知秋里搜」。搜全部书源的话，
  /// 同一个书名会从七八个源里冒出七八条重复结果，还得自己挑。
  /// 想看全部时，搜索页顶部那条「仅搜：xxx」点一下就放开。
  void _openSearch() {
    final provider = context.read<DiscoverProvider>();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(
          sourceUrl: provider.currentSourceUrl,
          sourceName: provider.currentSource?.bookSourceName,
        ),
      ),
    );
  }

  /// 一级分类 = 书源：在顶栏胶囊上左右滑动换上一个/下一个源。
  ///
  /// 【为什么不整页做成 PageView】每个源都要各自拉分类和书单，
  /// PageView 会一次性把相邻源也建出来，请求和内存都翻倍。
  /// 滑动换源 + 顶部胶囊显示当前源，观感一样但代价小得多。
  Future<void> _stepSource(List<BookSource> sources, int delta) async {
    final token = _token;
    if (token == null || sources.isEmpty) return;
    final provider = context.read<DiscoverProvider>();
    final idx = sources
        .indexWhere((s) => s.bookSourceUrl == provider.currentSourceUrl);
    // Dart 的 % 对负数返回非负结果（-1 % 5 == 4），所以来回滑不会越界
    final next = ((idx < 0 ? 0 : idx) + delta) % sources.length;
    if (next == idx) return;
    await provider.setCurrentSource(sources[next].bookSourceUrl);
    if (!mounted) return;
    await provider.reloadAfterSwitch(token);
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

    // 换书源 → 第二级要回到第一组。PageController 的初始页只在创建时生效，
    // 所以这里换一个全新的 controller（理由见 _groupPageController 的注释）。
    // 旧的那个要等这一帧画完再 dispose —— 它可能正被当前这棵 PageView 持有。
    if (_groupBarSourceUrl != provider.currentSourceUrl) {
      _groupBarSourceUrl = provider.currentSourceUrl;
      final old = _groupPageController;
      _groupPageController =
          PageController(viewportFraction: _groupViewportFraction);
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }

    return Scaffold(
      body: _buildBody(loggedIn, provider, sources),
    );
  }

  /// 整页是一个 CustomScrollView，顶栏和分类卡片都是 sliver。
  ///
  /// 【为什么把 AppBar 放进滚动视图里】参考里书单上滑时，搜索栏、书源胶囊、
  /// 分类卡片会**一起收起来**（图 image#2「向上滑动三级自动隐藏」），
  /// 让书单占满整屏。`Scaffold(appBar:)` 是固定的，做不到这件事；
  /// 换成 `SliverAppBar(floating: true, snap: true)` 之后：
  ///   - 上滑：顶栏滚出屏幕，分类卡片（下一个 sliver）也跟着滚出去；
  ///   - 稍微下滑：顶栏立刻弹回来（snap），分类卡片要再往下滚才出现。
  Widget _buildAppBarSliver(
      DiscoverProvider provider, List<BookSource> sources) {
    final theme = Theme.of(context);
    return SliverAppBar(
      floating: true,
      snap: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      titleSpacing: 4,
      leadingWidth: 56,
      leading: Center(
        child: IconButton(
          tooltip: '搜索当前书源',
          onPressed: _openSearch,
          icon: const Icon(Icons.search),
          style: IconButton.styleFrom(
            backgroundColor:
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            minimumSize: const Size(40, 40),
          ),
        ),
      ),
      // 横滑换源的手势挂在外层（见 _withSourceSwipe），这里只管显示
      title: _buildSourcePill(sources),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: provider.booksLoading ? null : _refreshAll,
          icon: const Icon(Icons.refresh),
        ),
        // 只有书源自己写了登录界面（loginUi / loginUrl）才显示人像 ——
        // 参考客户端里"没有登录界面的书源就没有头像"。
        if (provider.hasSourceLogin)
          Center(
            child: IconButton(
              tooltip: '书源登录',
              onPressed: _openSourceLogin,
              icon: const Icon(Icons.person_outline),
              style: IconButton.styleFrom(
                backgroundColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
                minimumSize: const Size(40, 40),
              ),
            ),
          ),
        const SizedBox(width: 6),
      ],
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
    // 没登录时也保留顶栏（搜索/书源胶囊），只把内容区换成提示 ——
    // 否则这一页的观感会和登录后完全脱节。所以统一走同一棵 sliver 树。
    if (!loggedIn) {
      return _withSourceSwipe(
        sources,
        RefreshIndicator(
          onRefresh: _refreshAll,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              _buildAppBarSliver(provider, sources),
              SliverFillRemaining(
                hasScrollBody: false,
                child: _CenterHint(
                  icon: Icons.lock_outline,
                  text: '登录后即可浏览书源的发现页',
                  actionText: '去登录',
                  onAction: () => Navigator.pushNamed(context, AppRoutes.login),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return _withSourceSwipe(
      sources,
      RefreshIndicator(
        onRefresh: _refreshAll,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildAppBarSliver(provider, sources),
            if (provider.categoriesLoading)
              const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2)),
            if (provider.sourcesLoading && sources.isEmpty)
              const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()))
            else if (sources.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _CenterHint(
                  icon: Icons.explore_off_rounded,
                  text: provider.sourcesError ??
                      '还没有开启「发现」的书源\n去书源管理里开一个吧',
                  actionText: '书源管理',
                  onAction: () =>
                      Navigator.pushNamed(context, AppRoutes.sourceManage),
                ),
              )
            else ...[
              SliverToBoxAdapter(child: _buildCategoryCard(provider)),
              ..._buildBookSlivers(provider),
            ],
          ],
        ),
      ),
    );
  }

  /// 整屏横滑 = 换书源（这就是「一级分类」）。
  ///
  /// 【为什么不只用顶栏胶囊上的手势】胶囊只有一百多像素宽，手指落在书单或
  /// 空白处横滑时也该能换源 —— 参考客户端就是整屏横滑。所以手势挂到最外层，
  /// 顶栏那层不再单独挂，避免两处逻辑各写一遍。
  ///
  /// 【为什么不会和分类行的横滑打架】Flutter 的手势竞技场里越深的 recognizer
  /// 越优先：手指落在分类行上时，那一行自己的横向 ListView 先接住手势，
  /// 这里的 onHorizontalDragEnd 根本不会触发；而且行内滑到边界后
  /// ClampingScrollPhysics 不会把剩余位移冒泡上来，所以不会出现
  /// 「想滑分类却切了书源」。
  ///
  /// 【为什么只有一个源时不挂】没得切，挂了只会白吃手势。
  Widget _withSourceSwipe(List<BookSource> sources, Widget child) {
    if (sources.length < 2) return child;
    return GestureDetector(
      // translucent：空白处（sliver 之间的间隙）也能接到手势
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v.abs() < 150) return; // 手抖不算
        _stepSource(sources, v < 0 ? 1 : -1);
      },
      child: child,
    );
  }

  /// 书单部分的 sliver。
  ///
  /// 【为什么要分这么多种】每种空/错状态都要占满剩余空间才好居中，
  /// 用 SliverFillRemaining；有书时用 SliverList 懒加载，滚到底自动加载下一页。
  List<Widget> _buildBookSlivers(DiscoverProvider provider) {
    // 没有可点的分类时上面那张卡片已经把原因说清楚了，
    // 这里再补一句「这个分类下暂时没有书」只会让人更糊涂。
    if (!provider.categoriesLoading &&
        provider.selectableCategories.isEmpty) {
      return const [SliverToBoxAdapter(child: SizedBox(height: 8))];
    }
    if (provider.booksLoading && provider.books.isEmpty) {
      return const [
        SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()))
      ];
    }
    if (provider.booksError != null && provider.books.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _CenterHint(
            icon: Icons.error_outline,
            text: provider.booksError!,
            actionText: '重试',
            onAction: _refreshAll,
          ),
        ),
      ];
    }
    if (provider.books.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(child: Text('这个分类下暂时没有书')),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: 4, bottom: 16),
        sliver: SliverList.builder(
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
              onTap: () => _openBook(book),
            );
          },
        ),
      ),
    ];
  }

  /// 分类卡片 = 第二级（分组标题，可左右滑）+ 第三级（该组的分类，行内可左右滑）。
  ///
  /// 【为什么第二级要独立成一条可滑的】参考客户端的发现页是三级：
  /// 一级书源（顶栏胶囊）→ 二级分组（「共享服」「我的」「小说」「首页」）→
  /// 三级分类。第二级本身要能左右滑着换 —— 用户的原话是「第二级左滑就是我的，
  /// 第二级小说就是新书强推」。所以它不能只是平铺分类里的一个"标题行"，
  /// 必须是独立的、能吸附的横滑列表。
  ///
  /// 【为什么三级行内不是平分宽度】`layout_flexBasisPercent` 只管「这一项该占
  /// 整行的百分之几」，用来决定**切行**；行内每个胶囊按自己的文字宽度铺开，
  /// 放不下就横向滑。参考图里知秋第二行「小说·共享章节数量 /
  /// 小说·共享章节字数」两个胶囊都是 9 个字，加起来略超一行，第二个就被
  /// 右边缘裁掉了 —— 平分宽度的话两个都会完整显示，对不上。
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

    final groups = provider.groups;
    if (groups.isEmpty) {
      // 分类项全是标题、一个可点的都没有（实测有这种源）
      return _CategoryNotice(
        text: provider.categoriesNote ?? '这个书源没有可点的分类',
      );
    }

    // 有多个分组才显示第二级 —— 只有一个组时那一行纯属占地方。
    // 实测有书源（半夏小说、屋檐下文学网）干脆没写分组标题，全部分类就是一整组。
    final showGroups = provider.showGroups;
    final items = showGroups ? provider.currentGroupItems : groups.first.items;

    final rows = packFlexRows<ExploreCategory>(
      items,
      (item) => item.safeBasis,
      wrapBeforeOf: (item) => item.wrapBefore,
    );
    final visibleRows =
        rows.length < _categoryMaxRows ? rows.length : _categoryMaxRows;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showGroups) _buildGroupBar(provider, groups),
          // 高度按「实际有几行」算，别写死三行 —— 70 个源里大多数只有一两行，
          // 写死的话卡片下半截永远是空的。分类上千个时（知秋 466 行）这里内部滚动，
          // 而且用 itemExtent 让行**懒构建** —— 全建出来是上万个 widget，
          // 切换书源时会明显卡一下。
          SizedBox(
            height: visibleRows * _categoryRowHeight,
            child: NotificationListener<ScrollNotification>(
              // 分类卡片自己也能纵向滚（知秋一组几十行），手指落在卡片上往上推时，
              // 手势会被这张卡片的 ListView 吃掉，外层的顶栏就收不起来 ——
              // 用户要的「上滑三级自动隐藏」在这个区域就失效了。
              // 这里把内层滚到边界后多出来的位移（overscroll）转给外层控制器，
              // 于是「先滚完分类、再收起顶栏」是一个连续动作。
              // 只转 Overscroll 不转 ScrollUpdate：内层还有滚动空间时不该带动外层。
              onNotification: _forwardOverscroll,
              child: ListView.builder(
                itemExtent: _categoryRowHeight,
                physics: const ClampingScrollPhysics(),
                itemCount: rows.length,
                itemBuilder: (context, index) =>
                    _buildCategoryRow(rows[index], provider),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 第二级：分组标题，整行居中，左右滑切换。
  ///
  /// 【为什么 viewportFraction 是 1.0】参考「轻阅时光」Windows 版的发现页
  /// （用户专门指了这个）—— 第二级那一行**只显示当前这一个分组标题、整行居中**，
  /// 不会像卡片轮播那样把左右邻组露出一截。之前设成 0.74 露出一半邻组，
  /// 和它长得不一样。
  ///
  /// 【右侧那个漏斗是干什么的】官方那一行右边有个筛选图标，点开是
  /// **全部分组的列表**（知秋有 83 组，一个个滑过去太慢）。这里照做：
  /// 点开列出来，选哪个直接跳过去。
  ///
  /// 【标题为什么原样显示】书源写的标题自带 emoji 装饰
  /// （`🟥 🟥 🟥  共享服  🟥 🟥 🟥`），参考客户端就是原样居中显示的 ——
  /// 那些"红方块"是 🟥 这个 emoji 本身，不是图片，清洗掉反而对不上。
  Widget _buildGroupBar(DiscoverProvider provider, List<ExploreGroup> groups) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _groupBarHeight,
      child: Row(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _groupPageController,
              itemCount: groups.length,
              onPageChanged: (i) {
                final token = _token;
                if (token != null) provider.setCurrentGroup(i, token);
              },
              itemBuilder: (context, i) => Center(
                child: Text(
                  groups[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ),
          ),
          // 分组可能几十个，纯靠滑太慢 —— 给一个直接跳转的入口
          SizedBox(
            width: 40,
            height: _groupBarHeight,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 19,
              tooltip: '全部分组',
              onPressed: () => _showGroupPicker(provider, groups),
              icon: Icon(Icons.filter_list,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 全部分组列表 —— 点哪个就跳到哪一组。
  ///
  /// 【为什么要它】知秋终版有 83 个分组，大灰狼 23 个。想从「共享服」滑到
  /// 「玄幻」，靠一下下左滑要滑几十次。官方那个漏斗图标就是干这个的。
  Future<void> _showGroupPicker(
      DiscoverProvider provider, List<ExploreGroup> groups) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.92,
          builder: (ctx, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Text('全部分组',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('${groups.length} 个',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: groups.length,
                  itemBuilder: (ctx, i) {
                    final selected = i == provider.groupIndex;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      title: Text(
                        groups[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      subtitle: Text('${groups[i].items.length} 个分类'),
                      trailing: selected
                          ? Icon(Icons.check,
                              size: 18, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => Navigator.pop(ctx, i),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    // 只跳页就行 —— onPageChanged 会带着 setCurrentGroup 一起跑，
    // 这里再调一次只会被 setCurrentGroup 的相等判断挡掉。
    if (_groupPageController.hasClients) {
      _groupPageController.jumpToPage(picked);
    }
  }

  /// 把分类卡片滚到边界后的剩余位移交给整页滚动。
  ///
  /// 正数 = 内容已到底还在往上推 → 外层 offset 变大（书单上移、顶栏收起）；
  /// 负数 = 到顶还在往下拉 → 外层往回滚（顶栏重新出现）。
  /// 用 jumpTo 而不是 animateTo：这里跟着手指走，动画会明显拖手。
  bool _forwardOverscroll(ScrollNotification n) {
    if (n is! OverscrollNotification) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    final d = n.overscroll;
    if (d == 0 || !_scrollController.hasClients) return false;
    final pos = _scrollController.position;
    final target = (_scrollController.offset + d).clamp(0.0, pos.maxScrollExtent);
    if ((target - _scrollController.offset).abs() < 0.5) return false;
    _scrollController.jumpTo(target);
    return false; // 继续向上冒泡，不影响其它监听者
  }

  /// 一行分类（第三级）—— 按 `layout_flexBasisPercent` 平分宽度。
  ///
  /// 【为什么从「横向滚动 + 按内容宽度」改成「平分」】参考「轻阅时光」
  /// Windows 版的发现页：一行两个分类各占一半，右边正好对齐卡片边缘；
  /// 之前按内容宽度铺开，第二个胶囊被右边缘裁掉一截，和它对不上。
  ///
  /// 书源给的占比本来就是「这一项该占整行的百分之几」，直接当 flex 用
  /// 才是它的原意。两个 0.4 的项相加是 0.8，按比例放大成各占 50% ——
  /// 和官方那种「铺满一行」的观感一致，而不是右边留 20% 的空白。
  Widget _buildCategoryRow(
      List<ExploreCategory> row, DiscoverProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          for (var i = 0; i < row.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              // flex 必须是正整数；占比 ×1000 保留三位小数足够
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

}

/// 一个分类（第三级）—— **纯文字，没有胶囊底色**。
///
/// 【为什么不是胶囊】参考「轻阅时光」Windows 版的发现页：第三级就是一行文字，
/// 选中的那项变成主题色、未选中的是灰色，靠**颜色**区分，不靠底色。
/// 之前做成胶囊（浅底圆角 + 选中淡主题色底），和它对不上。
///
/// 【不可点的项】就是书源自己写的分组标题（「🔴 玄幻 🔴」这类），
/// 颜色更淡一点，看起来像小标题而不是按钮。
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
    // 宽度按书源给的占比平分，长标题（「小说·共享章节数量」这类）会被截断 ——
    // 这是必然的：占比就那么大，想全显示只能牺牲排版一致性。
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: onTap == null
            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.65)
            : (selected ? primary : theme.colorScheme.onSurfaceVariant),
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        fontSize: 13.5,
      ),
    );

    if (onTap == null) return Center(child: text);

    // 没有底色，但点按还是要有点反馈 —— 用 ink 的圆形扩散就够了。
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Center(child: text),
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
