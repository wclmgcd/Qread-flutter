import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../pages/bookshelf/bookshelf_page.dart';
import '../pages/bookshelf/book_info_page.dart';
import '../pages/bookshelf/book_source_switch_page.dart';
import '../pages/discover/discover_page.dart';
import '../pages/rss/rss_page.dart';
import '../pages/profile/profile_page.dart';
import '../pages/profile/reading_preference_page.dart';
import '../pages/profile/tts_engine_page.dart';
import '../pages/reader/image_viewer_page.dart';
import '../pages/replace/replace_rule_editor_page.dart';
import '../pages/replace/replace_rule_page.dart';
import '../pages/reader/reader_page.dart';
import '../pages/search/search_page.dart';
import '../pages/settings/general_settings_page.dart';
import '../pages/login/login_page.dart';
import '../pages/login/source_login_page.dart';
import '../pages/login/webview_login_page.dart';
import '../pages/source/source_manage_page.dart';
import '../pages/source/book_source_editor_page.dart';
import '../pages/source/book_source_debug_page.dart';
import '../pages/rss/rss_source_page.dart';
import '../pages/rss/rss_source_editor_page.dart';
import '../pages/rss/rss_source_debug_page.dart';
import '../pages/discover/explore_books_page.dart';
import '../pages/rss/rss_article_list_page.dart';
import '../pages/rss/rss_article_detail_page.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/reader_provider.dart';
import '../providers/replace_rule_provider.dart';
import '../providers/rss_manage_provider.dart';
import '../providers/rss_provider.dart';
import '../providers/source_manage_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/app_settings.dart';
import '../services/md5_sync_service.dart';
import '../services/reader_ws_service.dart';
import '../services/tts_service.dart';

/// 全局路由观察器。
///
/// 用途：让页面能感知「自己上面那层路由被 pop 了，我又露出来了」——
/// 即 [RouteAware.didPopNext]。
///
/// 【为什么需要】书架从阅读页返回时，列表顺序不会自己更新：
/// 阅读页只改了内存里那本书的 `durChapterTime`，没有任何东西触发书架重排，
/// 所以用户必须手动下拉刷新才看到「刚读的书排到最前」。
/// 挂上这个 observer 后，书架页在 `didPopNext()` 里重排一次即可，
/// 而且**所有**返回路径都覆盖到（点封面进阅读、经书籍信息页进阅读……），
/// 不用在每处 `Navigator.push` 后面各写一遍。
///
/// 注意：必须在 `MaterialApp.navigatorObservers` 里注册才会生效。
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 全局 Navigator key。
///
/// 【为什么需要】
/// 「用其他应用打开一个 json」这个事件是从**原生侧**推过来的，
/// 触发时机完全不受路由控制 —— 可能在冷启动第一帧之前就到了。
/// 那种时刻能拿到的只有这个全局 key：`MaterialApp.builder` 里的 context
/// 位于 Navigator **之上**，`Navigator.of(context)` 会直接失败，
/// 必须用 `appNavigatorKey.currentState` 才能往导航栈上压页面。
///
/// 见 `lib/widgets/file_open_listener.dart`。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class AppRoutes {
  static const String home = '/';
  static const String login = '/login';
  static const String reader = '/reader';
  static const String search = '/search';
  static const String sourceManage = '/sourceManage';
  static const String bookSourceEditor = '/source/editor';
  static const String sourceLogin = '/source/login';
  static const String sourceWebLogin = '/source/weblogin';
  static const String sourceDebug = '/source/debug';
  static const String rssSource = '/rssSource';
  static const String rssSourceEditor = '/rss/source/editor';
  static const String rssSourceDebug = '/rss/source/debug';
  static const String replaceRules = '/replaceRules';
  static const String replaceRuleEditor = '/replaceRules/editor';
  static const String generalSettings = '/settings/general';
  static const String readingPreference = '/settings/reading';
  static const String ttsEngines = '/settings/tts';
  static const String bookInfo = '/book/info';
  static const String bookSourceSwitch = '/book/switchSource';
  static const String discoverExplore = '/discover/explore';
  static const String rssArticles = '/rss/articles';
  static const String rssArticleDetail = '/rss/article';

  static final Map<String, WidgetBuilder> routes = {
    home: (_) => const HomePage(),
    login: (_) => const LoginPage(),
    search: (_) => const SearchPage(),
    generalSettings: (_) => const GeneralSettingsPage(),
    readingPreference: (_) => const ReadingPreferencePage(),
    ttsEngines: (_) => const TtsEnginePage(),
    sourceManage: (_) => const SourceManagePage(),
    rssSource: (_) => const RssSourcePage(),
    replaceRules: (_) => const ReplaceRulePage(),
  };

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    if (settings.name == reader) {
      return MaterialPageRoute(
        settings: settings, // pass settings to preserve arguments
        builder: (_) => const ReaderPage(),
      );
    }
    if (settings.name == bookInfo) {
      final args = settings.arguments as BookInfoPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => BookInfoPage(args: args),
      );
    }
    if (settings.name == bookSourceSwitch) {
      final args = settings.arguments as BookSourceSwitchArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => BookSourceSwitchPage(args: args),
      );
    }
    if (settings.name == discoverExplore) {
      final args = settings.arguments as ExploreBooksPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => ExploreBooksPage(args: args),
      );
    }
    if (settings.name == bookSourceEditor) {
      final args = settings.arguments as BookSourceEditorPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => BookSourceEditorPage(args: args),
      );
    }
    if (settings.name == rssArticles) {
      final args = settings.arguments as RssArticleListPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => RssArticleListPage(args: args),
      );
    }
    if (settings.name == rssSourceEditor) {
      final args = settings.arguments as RssSourceEditorPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => RssSourceEditorPage(args: args),
      );
    }
    if (settings.name == rssArticleDetail) {
      final args = settings.arguments as RssArticleDetailPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => RssArticleDetailPage(args: args),
      );
    }
    if (settings.name == sourceLogin) {
      final args = settings.arguments as SourceLoginPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => SourceLoginPage(args: args),
      );
    }
    if (settings.name == sourceWebLogin) {
      final args = settings.arguments as WebViewLoginPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => WebViewLoginPage(args: args),
      );
    }
    if (settings.name == sourceDebug) {
      final args = settings.arguments as Map<String, String>;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => BookSourceDebugPage(args: args),
      );
    }
    if (settings.name == rssSourceDebug) {
      final args = settings.arguments as Map<String, String>;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => RssSourceDebugPage(args: args),
      );
    }
    if (settings.name == replaceRuleEditor) {
      final args = settings.arguments as ReplaceRuleEditorPageArgs;
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => ReplaceRuleEditorPage(args: args),
      );
    }
    return null;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  StreamSubscription<Md5Change>? _md5Sub;
  StreamSubscription<WsPushMessage>? _pushSub;
  Timer? _readDebounce;

  /// initState 里拿不到 Provider（要在 postFrame 之后），存下来给 dispose 用
  UserProvider? _userProvider;

  @override
  void initState() {
    super.initState();
    // 服务端推 logout（token 失效）→ 本地登出回登录页
    ReaderWsService.instance.onForceLogout = _forceLogout;
    // md5 族：其它端改了数据 → 刷新对应列表
    _md5Sub = Md5SyncService.instance.changes.listen(_onMd5Change);
    // 免回执的互动推送（openurl/searchBook/addBook/showPhoto/refreshBook*）
    _pushSub = ReaderWsService.instance.pushStream.listen(_onBackendNotify);
    // WS 变成全局连接：md5 同步要求 App 活着就连着，而不是只在阅读页/登录页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _userProvider = context.read<UserProvider>();
      _userProvider!.addListener(_syncWsConnection);
      _syncWsConnection();
    });
  }

  @override
  void dispose() {
    _userProvider?.removeListener(_syncWsConnection);
    _readDebounce?.cancel();
    _md5Sub?.cancel();
    _pushSub?.cancel();
    super.dispose();
  }

  void _syncWsConnection() {
    final user = _userProvider;
    if (user == null) return;
    if (user.isLoggedIn) {
      unawaited(ReaderWsService.instance.connect(user.token));
    } else {
      unawaited(ReaderWsService.instance.disconnect());
    }
  }

  Future<void> _forceLogout() async {
    if (!mounted) return;
    await _userProvider?.logout();
    appNavigatorKey.currentState
        ?.pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
    final ctx = appNavigatorKey.currentContext;
    if (ctx != null) {
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
        const SnackBar(content: Text('登录态已失效，请重新登录')),
      );
    }
  }

  // ============================================================
  // md5 族：其它端的数据变更 → 刷新对应数据
  // ============================================================

  void _onMd5Change(Md5Change change) {
    if (!mounted) return;
    final token = _userProvider?.token;
    if (token == null || token.isEmpty) return;
    switch (change.msg) {
      case 'bookmd5':
        unawaited(
            context.read<BookshelfProvider>().loadBookshelf(token, refresh: true));
        break;
      case 'read':
        // 阅读进度同步：另一台设备每翻一页都可能推一条，5s 防抖刷一次书架
        _readDebounce?.cancel();
        _readDebounce = Timer(const Duration(seconds: 5), () {
          if (!mounted) return;
          final t = _userProvider?.token;
          if (t == null || t.isEmpty) return;
          unawaited(
              context.read<BookshelfProvider>().loadBookshelf(t, refresh: true));
        });
        break;
      case 'sourcemd5':
        unawaited(
            context.read<SourceManageProvider>().loadSources(token, refresh: true));
        unawaited(context
            .read<DiscoverProvider>()
            .loadExploreSources(token, refresh: true));
        break;
      case 'rssmd5':
        unawaited(context.read<RssProvider>().loadSources(token, refresh: true));
        unawaited(
            context.read<RssManageProvider>().loadSources(token, refresh: true));
        break;
      case 'replacemd5':
        unawaited(
            context.read<ReplaceRuleProvider>().loadRules(token, refresh: true));
        break;
      case 'tssmd5':
        unawaited(TtsService().loadSelectedHttpEngine(token));
        break;
      case 'groundmd5':
        unawaited(context.read<BookshelfProvider>().loadGroups(token));
        break;
      case 'source':
      case 'allowchange':
        // 书源总开关 / 允许换源开关变了：跟着书源一起刷
        unawaited(
            context.read<SourceManageProvider>().loadSources(token, refresh: true));
        break;
      case 'gonggao':
        _showGonggao(change.md5);
        break;
    }
  }

  void _showGonggao(String text) {
    if (text.trim().isEmpty) return;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('公告'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 免回执互动推送（id 为空，官方客户端同样只执行不回执）
  // ============================================================

  void _onBackendNotify(WsPushMessage msg) {
    // 打开网页类由阅读页/登录页自己接（半截式弹窗 + 关页回执），这里不重复
    if (msg.isOpenPage) return;
    if (!mounted) return;
    final token = _userProvider?.token ?? '';
    switch (msg.msg) {
      case 'openurl':
        // url=目标地址，title=mimeType（官方用来决定打开方式，这里统一外部浏览器）
        final uri = Uri.tryParse(msg.url);
        if (uri != null) {
          unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
        }
        break;
      case 'addBook':
        // url=bookUrl：把这本书加进书架
        if (token.isEmpty || msg.url.isEmpty) return;
        unawaited(_addBookFromPush(token, msg.url));
        break;
      case 'searchBook':
        // url=sourceUrl（可空=全局搜），title=关键词
        final nav = appNavigatorKey.currentState;
        if (nav == null) return;
        unawaited(nav.push(MaterialPageRoute(
          builder: (_) => SearchPage(
            initialKeyword: msg.title,
            sourceUrl: msg.url.isEmpty ? null : msg.url,
          ),
        )));
        break;
      case 'showPhoto':
        final nav = appNavigatorKey.currentState;
        if (nav == null || msg.url.isEmpty) return;
        unawaited(nav.push(MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            url: msg.url,
            title: msg.title.isEmpty ? null : msg.title,
          ),
        )));
        break;
      case 'refreshBookInfo':
        if (token.isEmpty) return;
        unawaited(
            context.read<BookshelfProvider>().loadBookshelf(token, refresh: true));
        break;
      case 'refreshBookToc':
        unawaited(_refreshReaderIfOpen(msg.title));
        break;
      case 'refreshBookContent':
        unawaited(_refreshReaderIfOpen(msg.title, clearContent: true));
        break;
      case 'refreshExplore':
        if (token.isEmpty) return;
        final discover = context.read<DiscoverProvider>();
        // 发现页没加载过分类就不必刷 —— 刷出来也没有地方显示
        if (discover.categories.isNotEmpty) {
          unawaited(discover.reloadBooks(token));
        }
        break;
    }
  }

  Future<void> _addBookFromPush(String token, String bookUrl) async {
    try {
      await ApiService.instance.urlSaveBook(token, bookUrl);
      if (!mounted) return;
      unawaited(
          context.read<BookshelfProvider>().loadBookshelf(token, refresh: true));
      _homeSnack('已加入书架');
    } catch (e) {
      _homeSnack('加入书架失败: $e');
    }
  }

  /// 书源 JS 改了某本书的目录/正文 → 如果正在读这本书，刷新之。
  /// [clearContent] 为 true 时连本章内容缓存一起清（refreshBookContent）。
  Future<void> _refreshReaderIfOpen(String bookUrl,
      {bool clearContent = false}) async {
    if (bookUrl.isEmpty) return;
    final token = _userProvider?.token ?? '';
    if (token.isEmpty) return;
    try {
      final reader = context.read<ReaderProvider>();
      if (reader.book?.bookUrl != bookUrl) return; // 没在读这本书，忽略
      if (clearContent) await reader.clearLocalChapterCache();
      await reader.refreshChapters(token);
    } catch (_) {}
  }

  void _homeSnack(String text) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    // 「显示发现 / 显示订阅」来自阅读偏好设置（对齐 3.41 的
    // 「其他设置 → 显示订阅 / 显示发现」）。书架和「我的」始终保留。
    final settings = context.watch<AppSettings>();
    final pages = <Widget>[
      const BookshelfPage(),
      if (settings.showDiscover) const DiscoverPage(),
      if (settings.showSubscribe) const RssPage(),
      const ProfilePage(),
    ];
    final items = <BottomNavigationBarItem>[
      const BottomNavigationBarItem(
        icon: Icon(Icons.book_outlined),
        activeIcon: Icon(Icons.book),
        label: '书架',
      ),
      if (settings.showDiscover)
        const BottomNavigationBarItem(
          icon: Icon(Icons.explore_outlined),
          activeIcon: Icon(Icons.explore),
          label: '发现',
        ),
      if (settings.showSubscribe)
        const BottomNavigationBarItem(
          icon: Icon(Icons.rss_feed_outlined),
          activeIcon: Icon(Icons.rss_feed),
          label: '订阅',
        ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.person_outline),
        activeIcon: Icon(Icons.person),
        label: '我的',
      ),
    ];
    // 关掉某个 tab 后旧的下标可能越界（比如原来停在「订阅」）
    final index = _currentIndex.clamp(0, pages.length - 1);

    return Scaffold(
      body: IndexedStack(
        index: index,
        children: pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: index,
        onTap: (i) => setState(() => _currentIndex = i),
        items: items,
      ),
    );
  }
}
