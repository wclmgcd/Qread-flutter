import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../pages/bookshelf/bookshelf_page.dart';
import '../pages/bookshelf/book_info_page.dart';
import '../pages/bookshelf/book_source_switch_page.dart';
import '../pages/discover/discover_page.dart';
import '../pages/rss/rss_page.dart';
import '../pages/profile/profile_page.dart';
import '../pages/profile/reading_preference_page.dart';
import '../pages/profile/tts_engine_page.dart';
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
import '../services/app_settings.dart';

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
