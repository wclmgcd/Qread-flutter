import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart' as bp;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/routes.dart';
import '../../models/book.dart';
import '../../models/bookmark.dart';
import '../../models/chapter.dart';
import '../../models/reader_launch_args.dart';
import '../../models/tts_engine.dart';
import '../../pages/bookshelf/book_info_page.dart';
import '../../pages/bookshelf/book_source_switch_page.dart';
import '../../pages/bookshelf/book_toc_sheet.dart';
import '../../pages/login/source_login_page.dart';
import '../../pages/login/webview_login_page.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/reader_provider.dart';
import '../../providers/source_manage_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/app_log.dart';
import '../../services/app_settings.dart';
import '../../services/cookie_sync_service.dart';
import '../../services/notification_service.dart';
import '../../services/browsing_history_service.dart';
import '../../services/reader_ws_service.dart';
import '../../services/reading_stats_service.dart';
import '../../services/replace_rule_store.dart';
import '../../services/system_ui_service.dart';
import '../../services/tts_service.dart';
import '../../widgets/batch_download_dialog.dart';
import '../../widgets/book_cover.dart';
import 'engine/engine.dart';
import 'book_text_search_page.dart';
import 'paragraph_comment_page.dart';
import 'reader_selection_menu.dart';
import 'reader_state.dart';
import 'image_viewer_page.dart';
import 'widgets/reader_fonts.dart';
import 'widgets/widgets.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({Key? key}) : super(key: key);

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  static const _keyFontSize = 'reader_font_size';
  static const _keyLineHeight = 'reader_line_height';
  static const _keyAutoNext = 'reader_auto_next';
  static const _keyTheme = 'reader_theme';
  static const _keyPageMode = 'reader_page_mode';
  static const _keyAutoPageInterval = 'reader_auto_page_interval';
  static const _keyProgressChapterPrefix = 'reader_progress_ch_';
  static const _keyProgressPosPrefix = 'reader_progress_pos_';
  static const _keyScreenWakelock = 'reader_screen_wakelock';
  static const _keyShowPageNumber = 'reader_show_page_number';
  static const _keyVolumeKeyFlip = 'reader_volume_key_flip';
  static const _keyShowBottomBar = 'reader_show_bottom_bar';
  static const _keyShowTopBar = 'reader_show_top_bar';
  static const _keyParagraphSpacing = 'reader_paragraph_spacing';
  static const _keyFirstLineIndent = 'reader_first_line_indent';
  static const _keyHorizontalPadding = 'reader_horizontal_padding';
  static const _keyTopPadding = 'reader_top_padding';
  static const _keyPageAnimType = 'reader_page_anim_type';
  static const _keyBrightness = 'reader_brightness';
  static const _keyBrightnessAuto = 'reader_brightness_auto';
  static const _keyFontFamily = 'reader_font_family';
  static const _keyBoldText = 'reader_bold_text';
  static const _keyShowParagraphComment = 'reader_show_paragraph_comment';
  // 「听书设置」里的三个开关（对齐 3.41 的听书设置面板）
  static const _keyTtsAllowPageTurn = 'reader_tts_allow_page_turn';
  static const _keyTtsShowChapterSwitch = 'reader_tts_show_chapter_switch';
  static const _keyTtsDelayPageTurn = 'reader_tts_delay_page_turn';
  /// 老默认排版 → 官方客户端同款排版 的一次性迁移标记
  static const _keyLayoutMigrated = 'reader_layout_migrated_v2';
  // ---- 更多设置（轻阅时光对齐批）----
  static const _keyHideTitle = 'reader_hide_title';
  static const _keyTitleAlign = 'reader_title_align';
  static const _keyShowHfDivider = 'reader_show_hf_divider';
  static const _keyProgressMode = 'reader_progress_mode';
  static const _keyShowFooterTime = 'reader_show_footer_time';
  static const _keyShowFooterBattery = 'reader_show_footer_battery';
  static const _keyBottomAlignLast = 'reader_bottom_align_last';
  static const _keyHideStatusBar = 'reader_hide_status_bar';
  static const _keyLockOrientation = 'reader_lock_orientation';
  static const _keyWakelockMinutes = 'reader_wakelock_minutes';
  static const _keySliderByPage = 'reader_slider_by_page';
  static const _keySwipeUpExit = 'reader_swipe_up_exit';
  static const _keySwipeDownBookmark = 'reader_swipe_down_bookmark';
  static const _keyTocReversed = 'reader_toc_reversed';

  late PageController _pageController;
  final PagedReaderController _pagedReaderController = PagedReaderController();

  /// 当前是否有文字被选中（`SelectionArea` 的选区状态）。
  /// 用它让「单击」在选区存在时只做「取消选中」，不翻页。
  bool _hasSelection = false;

  /// 当前选中的纯文本（已 trim）。
  ///
  /// `SelectableRegionState` 没有公开「取选中文本」的方法，唯一官方通道是
  /// `SelectionArea.onSelectionChanged`，所以在这里接住、给选中菜单用。
  String _selectedText = '';

  /// 最近一次 `SelectionArea` 的状态对象，用来主动清除选区。
  SelectableRegionState? _selectionState;
  final ScrollController _comicScrollController = ScrollController();
  final ScrollController _novelScrollController = ScrollController();
  final TtsService _tts = TtsService();
  final bp.Battery _battery = bp.Battery();
  final PaginationEngine _paginationEngine = PaginationEngine();

  ReaderProvider? _readerProvider;
  Timer? _metaTimer;
  Timer? _autoPageTimer;
  Timer? _ttsSleepTimer;
  StreamSubscription<WsPushMessage>? _wsSubscription;
  bool _openingCommentPage = false;

  /// 控制栏（引导条）自动隐藏延时。
  ///
  /// 之前**根本没有**自动隐藏 —— 点出控制栏后只能再点一次中间才会收，
  /// 于是它会一直盖在正文上（用户反馈「不会自动隐藏，安卓和 iOS 都不行」）。
  /// 4 秒是照着官方 3.41 的手感定的，想调只改这一个常量。
  static const Duration _controllerAutoHideDelay = Duration(seconds: 4);

  /// 控制栏交互计数。
  ///
  /// 【为什么需要它】倒计时本身由 `ControllerOverlay` 自己持有
  /// （它只会在控制栏可见时存在，`initState` 里就排好倒计时，见
  /// controller_overlay.dart 的注释）。页面这边只需要在用户「又操作了一下」
  /// 时把这个计数 +1，控制栏就会把倒计时往后推。
  int _controllerRestartToken = 0;

  /// 控制栏的**页面级**兜底倒计时。
  ///
  /// 用户反馈「屏幕底部的小横条还是自动无法隐藏」—— 说明只靠
  /// `ControllerOverlay` 自己那一个倒计时仍然有失效的可能（比如某一版构建
  /// 里那段代码没生效、或某条显示路径没走到）。这里再补一条完全独立的
  /// 路径：两条倒计时都指向 `_hideController`，**任意一条活着**控制栏都会收，
  /// 从「单点」变成「双保险」。
  Timer? _controllerHideTimer;

  /// 自动翻页控制条的兜底倒计时（它原来**完全没有**自动隐藏）。
  Timer? _autoPageBarTimer;

  /// 「屏幕常亮」档位（5/10 分钟）的倒计时；到点自动放屏，翻页/点击会刷新。
  Timer? _wakelockTimer;

  /// 自动翻页控制条自动隐藏延时。
  static const Duration _autoPageBarHideDelay = Duration(seconds: 4);

  String? _token;
  String? _bookUrl;

  // 目录/书签跳章时由 ReaderLaunchArgs 带进来的落点，只在首次开章用一次
  int? _launchChapterIndex;
  int _launchChapterPosition = 0;
  bool _launchOpenAtEnd = false;

  List<Bookmark> _bookmarks = [];
  List<GlobalKey> _paragraphKeys = [];

  // 使用集中状态对象
  final ReaderState _state = ReaderState();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // 阅读页进入「全屏沉浸」：把屏幕底部那条系统手势条收起来
    // （走原生 WindowInsetsController，理由见 SystemUiService 的注释）
    unawaited(SystemUiService.hideNavigationBar());
    _loadSettings();
    _comicScrollController.addListener(_onComicScroll);
    _tts.addListener(_onTtsStateChanged);
    // 「替换净化」规则在别处改了（设置页改规则 / 换执行端 / 切净化总开关）
    // → 本页的排版缓存必须作废重排，否则用户改完规则回来看到的还是旧正文，
    // 只能手动点顶栏那个「刷新」。见 [_onReplaceRulesChanged]。
    ReplaceRuleStore.instance.addListener(_onReplaceRulesChanged);
    _startMetaTicker();
    _listenBackendPush();
    // 监听前后台切换 —— 「阅读偏好 → 后台播放」关掉时，切到后台要停朗读。
    WidgetsBinding.instance.addObserver(this);
    // 通知栏上的朗读控制按钮（上一段 / 暂停 / 停止）回调到本页的方法。
    // 页面销毁时必须摘掉 —— 否则通知点一下会去调一个已经 dispose 的 State。
    NotificationService.instance.onTtsAction = _onTtsNotificationAction;
    // 音量键翻页：原生侧把音量键消费掉后从这里推事件（"up"/"down"）。
    // 监听器的注册与设置无关 —— active 与否由原生侧 volumeKeyFlipActive 决定，
    // 这里只管收事件；是否真的翻页再看一次开关，防止设置刚关、事件已到。
    SystemUiService.setVolumeKeyListener(_onVolumeKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initBook());
    _ensureFontsThenRepaginate();
  }

  /// 音量键翻页事件（原生 dispatchKeyEvent 推过来的 "up"/"down"）。
  void _onVolumeKey(String direction) {
    if (!mounted || !_state.volumeKeyFlip) return;
    final provider = _readerProvider;
    if (provider == null) return;
    _refreshWakelockTimer();
    if (_state.isScrollMode) {
      _scrollByVolumeKey(direction);
    } else if (direction == 'down') {
      _nextPage(provider);
    } else {
      _previousPage(provider);
    }
  }

  /// 滚动/漫画模式下音量键 = 滚一屏的 90%。
  void _scrollByVolumeKey(String direction) {
    final controller =
        _state.isComic ? _comicScrollController : _novelScrollController;
    if (!controller.hasClients) return;
    final step = controller.position.viewportDimension * 0.9 *
        (direction == 'down' ? 1 : -1);
    final target = (controller.offset + step).clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    controller.animateTo(target,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  /// 通知栏朗读按钮被点了。
  ///
  /// 走的是和底部控制栏同一批方法，保证「在通知栏按暂停」和
  /// 「在 App 里按暂停」走完全一致的路径，不会出现两套状态。
  Future<void> _onTtsNotificationAction(String action) async {
    switch (action) {
      case NotificationService.actionPrev:
        _ttsSkipParagraph(-1);
        break;
      case NotificationService.actionToggle:
        if (_tts.isPlaying) {
          await _pauseTts();
        } else {
          await _resumeTts();
        }
        break;
      case NotificationService.actionStop:
        await _stopTts();
        break;
    }
  }

  /// 字体就绪后补排一次。
  ///
  /// 【为什么需要】pubspec 声明的字体是懒加载的，第一次用到才异步读 ttf。
  /// 如果进阅读页时字体还没读完，首次分页量到的是**回退字体**的行宽，
  /// 断行位置会偏 —— 表现就是「一句正常的话被断开到下一段」，而换一种
  /// 字体（换掉缓存 key → 强制重排）就恢复正常。
  /// 这里等预加载完成后，把分页缓存清掉重排一次，从根上消掉这个竞态。
  void _ensureFontsThenRepaginate() {
    // 进页面时已经就绪（绝大多数情况，main() 里就开始预热了）→ 不用管
    if (ReaderFont.fontsReady) return;
    unawaited(ReaderFont.preload().then((_) {
      if (!mounted) return;
      // 缓存里那份是用回退字体算的，必须整体作废
      _state.layoutCache.clear();
      _state.prefetchedNextLayout = null;
      _state.prefetchedNextChapterIndex = -1;
      _state.prefetchedPrevLayout = null;
      _state.prefetchedPrevChapterIndex = -1;
      final provider = _readerProvider;
      if (provider == null) return;
      setState(() {});
      _rebuildPages(provider);
    }));
  }

  @override
  void dispose() {
    ReplaceRuleStore.instance.removeListener(_onReplaceRulesChanged);
    _readerProvider?.removeListener(_onProviderChanged);
    _metaTimer?.cancel();
    _autoPageTimer?.cancel();
    _controllerHideTimer?.cancel();
    _autoPageBarTimer?.cancel();
    _ttsSleepTimer?.cancel();
    _wsSubscription?.cancel();
    ReaderWsService.instance.onToast = null;
    _comicScrollController.removeListener(_onComicScroll);
    _comicScrollController.dispose();
    _novelScrollController.dispose();
    _pageController.dispose();
    _pagedReaderController.dispose();
    NotificationService.instance.onTtsAction = null;
    WidgetsBinding.instance.removeObserver(this);
    _tts.removeListener(_onTtsStateChanged);
    _tts.stop();
    // 朗读通知是常驻的，页面关了必须显式收掉 —— 否则会一直挂在通知栏，
    // 而且 Android 上前台服务不退出，系统会认为 App 还在「干活」。
    unawaited(NotificationService.instance.cancelTts());
    // 离开阅读页要把系统导航栏还回来，否则整个 App 都点不到底部手势条
    unawaited(SystemUiService.showSystemBars());
    // 更多设置的系统类开关也要一并还回去：iOS 的 showSystemBars 只恢复
    // home indicator，状态栏/常亮/音量键/方向锁都得显式复位。
    SystemUiService.setVolumeKeyListener(null);
    unawaited(SystemUiService.setVolumeKeyActive(false));
    unawaited(SystemUiService.setKeepScreenOn(false));
    unawaited(SystemUiService.setStatusBarHidden(false));
    unawaited(SystemChrome.setPreferredOrientations(const []));
    _wakelockTimer?.cancel();
    _saveProgressSync();
    unawaited(ReadingStatsService.instance.endSession());
    super.dispose();
  }

  // ============================================================
  // 后端推送（段评 / 书源交互）
  // ============================================================

  void _listenBackendPush() {
    _wsSubscription?.cancel();
    _wsSubscription =
        ReaderWsService.instance.pushStream.listen(_onBackendPush);
    ReaderWsService.instance.onToast = (message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    };
  }

  void _onBackendPush(WsPushMessage message) {
    if (!mounted) return;
    if (!message.isOpenPage) return;
    if (message.url.trim().isEmpty) return;

    // 段评页用「段评」标题，其它（登录页/验证码）用后端给的标题
    final title = message.title.trim().isEmpty ? '段评' : message.title.trim();
    _openingCommentPage = false;
    // 段评统一用「半截式底部弹出」（对齐大灰狼书源）。
    // 后端 startBrowserdp 是段评专用通道，startBrowser 是通用通道
    // （登录 / 验证码 / 购买），但用户要求段评一律半截式，所以两者都走弹窗。
    _openWebPage(
      url: message.url,
      title: title,
      headers: message.headerMap,
      requestId: message.id,
      asSheet: true,
    );
  }

  /// 打开后端推来的网页。
  ///
  /// [asSheet] = true → 「半截式底部弹出」（段评的观感，上方露出正文）；
  /// false → 整页路由（需要整屏的表单，比如登录 / 验证码）。
  void _openWebPage({
    required String url,
    required String title,
    Map<String, String> headers = const {},
    String? requestId,
    bool asSheet = true,
  }) {
    if (!mounted) return;
    final page = ParagraphCommentPage(
      url: url,
      title: title,
      headers: headers,
      requestId: requestId,
      token: _token,
      embedded: asSheet,
    );

    if (!asSheet) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      return;
    }

    // 弹窗本身就是一个路由，关闭时 page 的 dispose() 会触发 → 回执照发。
    unawaited(showHalfSheet(context, child: page, title: title));
  }

  /// 点击正文里的段评气泡
  ///
  /// 气泡自带 `click`（形如 `showCmt(bid,cid,pid,ts)`），
  /// 把它包成 JS 规则交给后端执行，后端执行完会通过 WebSocket 把
  /// 段评页 URL 推回来（见 [_onBackendPush]）。
  /// 点正文插图 → 打开大图查看器。
  ///
  /// 【为什么传的是拼好的最终地址】
  /// 不少书源的图要经后端 `/imageDecode` 用 JS 规则解密才能显示，
  /// 直接拿原始 src 去加载只会得到一团乱码。这里的 url 已经是
  /// [_buildImageUrl] 处理过的，查看器拿去就能用。
  void _openImageViewer(String url) {
    if (url.isEmpty) return;
    final title = _displayedChapter(context.read<ReaderProvider>())?.title;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImageViewerPage(url: url, title: title),
      ),
    );
  }

  Future<void> _openParagraphComment(ParagraphComment comment) async {
    final token = _token;
    if (token == null) return;
    if (!comment.isTappable) {
      // 书源没给 JS 就点不动。不同书源的键名不一样
      // （起点系 `click`、番茄/大灰狼系 `js`），这里记一笔方便排查。
      AppLog.add('段评不可点：标记里没有 click/js（style=${comment.style}）');
      return;
    }
    if (_openingCommentPage) return;
    final provider = context.read<ReaderProvider>();
    final source = provider.book?.origin ?? provider.book?.originName ?? '';
    final bookUrl = _bookUrl ?? provider.book?.bookUrl ?? '';

    _openingCommentPage = true;
    try {
      AppLog.add('打开段评：${comment.click.substring(0, comment.click.length.clamp(0, 60))}');
      final resolved = await ApiService.instance.getOpenUrl(
        token,
        bookSourceUrl: source,
        url: '<js>${comment.click}</js>',
        bookurl: bookUrl,
      );
      if (!mounted) return;
      // 正常情况下后端已经通过 WebSocket 推了 startBrowserdp，
      // 这里只做兜底：拿到可用的 http(s) 地址就直接打开（同样是半截式）。
      final usable = resolved.startsWith('http') && !resolved.endsWith('/null');
      if (usable && _openingCommentPage) {
        _openingCommentPage = false;
        AppLog.add('段评兜底直开：$resolved');
        _openWebPage(url: resolved, title: '段评', asSheet: true);
        return;
      }
      // 没拿到可用地址，且 WebSocket 也没推（_openingCommentPage 仍为 true）
      if (_openingCommentPage) {
        _openingCommentPage = false;
        AppLog.add('段评打开失败：后端未返回可用地址（$resolved）');
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('段评打开失败，请检查后端连接'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _openingCommentPage = false;
      AppLog.add('段评异常：$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('段评打开失败: $e')),
      );
    }
  }

  // ============================================================
  // 设置持久化
  // ============================================================

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    // 老版本（≤ v3.4.5）的默认排版和官方客户端差得比较远
    // （字号 18 / 行距 1.8 / 边距 24 / 羊皮纸背景）。
    // 用户要求 App 排版与后端 Web 端统一，所以升级后做一次一次性迁移：
    // 只有「还停留在老默认值」的项才改写，用户自己调过的值不动。
    final needMigrate = !(prefs.getBool(_keyLayoutMigrated) ?? false);
    setState(() {
      _state.fontSize = prefs.getDouble(_keyFontSize) ?? 28.0;
      _state.lineHeight = prefs.getDouble(_keyLineHeight) ?? 1.5;
      _state.autoNext = prefs.getBool(_keyAutoNext) ?? true;
      _state.theme = prefs.getString(_keyTheme) ?? 'green';
      _state.pageMode = prefs.getString(_keyPageMode) ?? 'paged';
      _state.autoPageInterval = prefs.getDouble(_keyAutoPageInterval) ?? 12.0;
      // 常亮档位：新 int 键优先；老设备只有 bool 键时迁移语义（true=常亮/-1）。
      _state.wakelockMinutes = prefs.getInt(_keyWakelockMinutes) ??
          ((prefs.getBool(_keyScreenWakelock) ?? true) ? -1 : 0);
      // 显示进度四档：同理，老的 bool「显示页码」映射到 关/本章。
      _state.progressMode = prefs.getInt(_keyProgressMode) ??
          ((prefs.getBool(_keyShowPageNumber) ?? true) ? 1 : 0);
      _state.volumeKeyFlip = prefs.getBool(_keyVolumeKeyFlip) ?? false;
      _state.showBottomBar = prefs.getBool(_keyShowBottomBar) ?? true;
      _state.showTopBar = prefs.getBool(_keyShowTopBar) ?? true;
      _state.paragraphSpacing = prefs.getDouble(_keyParagraphSpacing) ?? 7.0;
      _state.firstLineIndent = prefs.getDouble(_keyFirstLineIndent) ?? 2.0;
      _state.horizontalPadding = prefs.getDouble(_keyHorizontalPadding) ?? 16.0;
      _state.topPadding = prefs.getDouble(_keyTopPadding) ?? 10.0;
      _state.brightness = prefs.getDouble(_keyBrightness) ?? 1.0;
      _state.brightnessAuto = prefs.getBool(_keyBrightnessAuto) ?? false;
      _state.fontFamily = prefs.getString(_keyFontFamily) ?? 'default';
      _state.boldText = prefs.getBool(_keyBoldText) ?? false;
      _state.showParagraphComment =
          prefs.getBool(_keyShowParagraphComment) ?? true;
      _state.hideTitle = prefs.getBool(_keyHideTitle) ?? false;
      _state.titleAlign = prefs.getInt(_keyTitleAlign) ?? 1;
      _state.showHeaderFooterDivider =
          prefs.getBool(_keyShowHfDivider) ?? false;
      _state.showFooterTime = prefs.getBool(_keyShowFooterTime) ?? true;
      _state.showFooterBattery = prefs.getBool(_keyShowFooterBattery) ?? true;
      _state.bottomAlignLastPage = prefs.getBool(_keyBottomAlignLast) ?? false;
      _state.hideStatusBar = prefs.getBool(_keyHideStatusBar) ?? false;
      _state.lockOrientation = prefs.getBool(_keyLockOrientation) ?? false;
      _state.sliderByPage = prefs.getBool(_keySliderByPage) ?? false;
      _state.swipeUpExit = prefs.getBool(_keySwipeUpExit) ?? false;
      _state.swipeDownBookmark = prefs.getBool(_keySwipeDownBookmark) ?? false;
      _state.tocReversed = prefs.getBool(_keyTocReversed) ?? false;
      _state.ttsAllowPageTurn =
          prefs.getBool(_keyTtsAllowPageTurn) ?? true;
      _state.ttsShowChapterSwitch =
          prefs.getBool(_keyTtsShowChapterSwitch) ?? true;
      _state.ttsDelayPageTurn =
          prefs.getBool(_keyTtsDelayPageTurn) ?? true;
      if (needMigrate) {
        if (_state.fontSize == 18.0) _state.fontSize = 28.0;
        if (_state.lineHeight == 1.8) _state.lineHeight = 1.5;
        if (_state.theme == 'light') _state.theme = 'green';
        if (_state.paragraphSpacing == 10.0) _state.paragraphSpacing = 7.0;
        if (_state.horizontalPadding == 24.0) _state.horizontalPadding = 16.0;
        if (_state.topPadding == 18.0) _state.topPadding = 10.0;
      }
      final rawAnimType = prefs.get(_keyPageAnimType);
      if (rawAnimType is String) {
        _state.applyPageAnimType(PageAnimType.fromId(rawAnimType));
      } else if (rawAnimType is int) {
        _state.applyPageAnimType(PageAnimType.fromLegacyIndex(rawAnimType));
      } else if (_state.pageMode == 'scroll') {
        _state.applyPageAnimType(PageAnimType.scroll);
      } else {
        _state.applyPageAnimType(PageAnimType.cover);
      }
    });
    if (needMigrate) {
      // 迁移后的值要落盘，否则下次启动又会从旧值读回来
      await _saveSettings();
      await prefs.setBool(_keyLayoutMigrated, true);
    }
    // 设置读完就把系统类开关（状态栏/常亮/音量键/方向锁）应用到原生侧
    _applySystemUiSettings();
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _state.fontSize);
    await prefs.setDouble(_keyLineHeight, _state.lineHeight);
    await prefs.setBool(_keyAutoNext, _state.autoNext);
    await prefs.setString(_keyTheme, _state.theme);
    await prefs.setString(
      _keyPageMode,
      _state.pageAnimType.usesScrollReader ? 'scroll' : 'paged',
    );
    await prefs.setDouble(_keyAutoPageInterval, _state.autoPageInterval);
    await prefs.setInt(_keyWakelockMinutes, _state.wakelockMinutes);
    await prefs.setInt(_keyProgressMode, _state.progressMode);
    await prefs.setBool(_keyVolumeKeyFlip, _state.volumeKeyFlip);
    await prefs.setBool(_keyShowBottomBar, _state.showBottomBar);
    await prefs.setBool(_keyShowTopBar, _state.showTopBar);
    await prefs.setDouble(_keyParagraphSpacing, _state.paragraphSpacing);
    await prefs.setDouble(_keyFirstLineIndent, _state.firstLineIndent);
    await prefs.setDouble(_keyHorizontalPadding, _state.horizontalPadding);
    await prefs.setDouble(_keyTopPadding, _state.topPadding);
    await prefs.setString(_keyPageAnimType, _state.pageAnimType.id);
    await prefs.setDouble(_keyBrightness, _state.brightness);
    await prefs.setBool(_keyBrightnessAuto, _state.brightnessAuto);
    await prefs.setString(_keyFontFamily, _state.fontFamily);
    await prefs.setBool(_keyBoldText, _state.boldText);
    await prefs.setBool(_keyShowParagraphComment, _state.showParagraphComment);
    await prefs.setBool(_keyHideTitle, _state.hideTitle);
    await prefs.setInt(_keyTitleAlign, _state.titleAlign);
    await prefs.setBool(_keyShowHfDivider, _state.showHeaderFooterDivider);
    await prefs.setBool(_keyShowFooterTime, _state.showFooterTime);
    await prefs.setBool(_keyShowFooterBattery, _state.showFooterBattery);
    await prefs.setBool(_keyBottomAlignLast, _state.bottomAlignLastPage);
    await prefs.setBool(_keyHideStatusBar, _state.hideStatusBar);
    await prefs.setBool(_keyLockOrientation, _state.lockOrientation);
    await prefs.setBool(_keySliderByPage, _state.sliderByPage);
    await prefs.setBool(_keySwipeUpExit, _state.swipeUpExit);
    await prefs.setBool(_keySwipeDownBookmark, _state.swipeDownBookmark);
    await prefs.setBool(_keyTocReversed, _state.tocReversed);
    await prefs.setBool(_keyTtsAllowPageTurn, _state.ttsAllowPageTurn);
    await prefs.setBool(_keyTtsShowChapterSwitch, _state.ttsShowChapterSwitch);
    await prefs.setBool(_keyTtsDelayPageTurn, _state.ttsDelayPageTurn);
  }

  // ============================================================
  // 元信息（时间、电量）
  // ============================================================

  void _startMetaTicker() {
    _refreshBattery();
    _metaTimer?.cancel();
    _metaTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _refreshBattery();
      if (mounted) setState(() => _state.now = DateTime.now());
    });
  }

  Future<void> _refreshBattery() async {
    try {
      final level = await _battery.batteryLevel;
      if (!mounted) return;
      setState(() {
        _state.batteryLevel = level;
        _state.now = DateTime.now();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _state.now = DateTime.now());
    }
  }

  // ============================================================
  // 初始化
  // ============================================================

  void _initBook() {
    final args = ModalRoute.of(context)?.settings.arguments;
    Book? book;
    if (args is ReaderLaunchArgs) {
      book = args.book;
      _launchChapterIndex = args.chapterIndex;
      _launchChapterPosition = args.chapterPosition;
      _launchOpenAtEnd = args.openAtEnd;
    } else if (args is Book) {
      book = args;
    }
    if (book == null) return;
    ReadingStatsService.instance.startSession();
    _token = context.read<UserProvider>().token;
    // 记浏览历史要带 token —— 服务端按用户存，才能跨端同步。
    // 顺序上必须放在 _token 赋值之后。
    unawaited(BrowsingHistoryService.instance.recordBook(_token, book));
    _state.isComic = book.type == 2;
    _bookUrl = book.bookUrl;
    _tts.init();
    // 恢复「我的 → 朗读引擎」里选中的那个 HTTP 引擎（选了它就不再走系统语音）
    unawaited(_tts.loadSelectedHttpEngine(_token));
    // 段评靠后端 WebSocket 推送，进阅读页就把长连接拉起来
    unawaited(ReaderWsService.instance.connect(_token));
    final provider = context.read<ReaderProvider>();
    _readerProvider = provider;
    provider.setBook(book);
    provider.addListener(_onProviderChanged);
    if (_token != null) {
      provider.loadChapters(_token!, loadInitialContent: false);
      _loadBookmarks();
    }
  }

  Future<void> _loadBookmarks() async {
    if (_token == null || _bookUrl == null) return;
    try {
      final rawList =
          await ApiService.instance.getBookmarks(_token!, _bookUrl!);
      final marks = rawList.map((e) => Bookmark.fromJson(e)).toList();
      if (!mounted) return;
      setState(() {
        _bookmarks = marks;
      });
    } catch (_) {}
  }

  void _onProviderChanged() {
    if (!mounted) return;
    final provider = context.read<ReaderProvider>();
    if (_token != null &&
        !_state.initialChapterOpened &&
        !provider.loadingChapters &&
        provider.chapters.isNotEmpty) {
      _state.initialChapterOpened = true;
      final initialIndex = (_launchChapterIndex ??
              provider.book?.durChapterIndex ??
              0)
          .clamp(0, provider.chapters.length - 1);
      // 明确指定了章节（目录/书签跳转）就按指定落点开，别再被上次进度拽回去
      if (_launchChapterIndex != null) {
        _openChapter(
          initialIndex,
          chapterPosition: _launchChapterPosition,
          openAtEnd: _launchOpenAtEnd,
        );
        return;
      }
      // 优先从本地读取页级进度
      _loadProgressLocalPos().then((localPos) {
        if (!mounted) return;
        int chapterPos;
        if (localPos != null && localPos > 1) {
          chapterPos = localPos.round();
        } else {
          final serverPos = provider.book?.durChapterPos ?? 0;
          chapterPos = serverPos > 1 ? serverPos : 0;
        }
        final openAtEnd = chapterPos > 1 << 29;
        _openChapter(
          initialIndex,
          chapterPosition: chapterPos,
          openAtEnd: openAtEnd,
        );
      });
    }
  }

  void _onTtsStateChanged() {
    if (!mounted) return;
    setState(() {});
    // 朗读状态变了 → 同步到通知栏（内部有节流，不会每个字都重发）
    unawaited(_syncTtsNotification());
  }

  /// 上次发通知时的朗读状态 —— 用来节流（见 [_syncTtsNotification]）。
  bool? _lastTtsNotifiedPlaying;
  String? _lastTtsNotifiedChapter;

  /// 把当前朗读状态同步到通知栏。
  ///
  /// 【为什么要节流】flutter_tts 的 progress 回调每读一个字都会 notifyListeners，
  /// 不加闸的话通知会被每秒重发好几次 —— Android 上表现为通知条闪烁、整机掉帧。
  /// 这里只在「播/停状态」或「章节标题」真正变化时才重发。
  Future<void> _syncTtsNotification() async {
    if (!_state.ttsReading) {
      _lastTtsNotifiedPlaying = null;
      _lastTtsNotifiedChapter = null;
      await NotificationService.instance.cancelTts();
      return;
    }
    final provider = _readerProvider;
    final chapterTitle =
        provider == null ? '' : (_displayedChapter(provider)?.title ?? '');
    final playing = _tts.isPlaying;
    if (playing == _lastTtsNotifiedPlaying &&
        chapterTitle == _lastTtsNotifiedChapter) {
      return;
    }
    _lastTtsNotifiedPlaying = playing;
    _lastTtsNotifiedChapter = chapterTitle;

    // 第一次朗读时才弹系统权限框（Android 13+ / iOS），
    // 不在启动时就问 —— 那样用户还没用功能就被问一遍，几乎必点拒绝。
    final granted = await NotificationService.instance.requestPermission();
    if (!granted || !mounted) return;
    await NotificationService.instance.showTts(
      bookName: provider?.book?.name ?? '',
      chapterTitle: chapterTitle,
      playing: playing,
    );
  }

  /// 切到后台/锁屏时的处理 —— 让「后台播放」开关真正生效。
  ///
  /// 【这个开关以前是死的】它在「阅读偏好」里能开能关、也存进了
  /// SharedPreferences，但没有任何代码读它，开关等于摆设。
  /// 这里补上：关掉时切后台就停朗读；打开时保持（配合前台服务通知，
  /// 系统不会把还在发声的进程收走）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.paused) return;
    if (!_state.ttsReading) return;
    if (AppSettings.instance.ttsBackground) return;
    unawaited(_stopTts());
  }

  void _onComicScroll() {
    if (!_state.autoNext || !_comicScrollController.hasClients) return;
    final maxExtent = _comicScrollController.position.maxScrollExtent;
    if (maxExtent <= 0) return;
    if (_comicScrollController.position.pixels >= maxExtent - 100) {
      final provider = context.read<ReaderProvider>();
      if (_state.hasNextChapter(
              _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
              provider.chapters.length) &&
          !_state.loadingDisplayedChapter &&
          _token != null) {
        _goToNextChapter();
      }
    }
  }

  // ============================================================
  // 进度与位置
  // ============================================================

  double _getProgress() {
    if (_state.isComic) {
      if (!_comicScrollController.hasClients) return 0.0;
      final max = _comicScrollController.position.maxScrollExtent;
      if (max <= 0) return 0.0;
      return (_comicScrollController.offset / max).clamp(0.0, 1.0);
    }
    if (_state.pageAnimType.usesScrollReader) {
      if (!_novelScrollController.hasClients) return 0.0;
      final max = _novelScrollController.position.maxScrollExtent;
      if (max <= 0) return 0.0;
      return (_novelScrollController.offset / max).clamp(0.0, 1.0);
    }
    return _state.chapterPosition.toDouble();
  }

  int _activePageIndex() {
    if (_pageController.hasClients) {
      final page = _pageController.page;
      if (page != null) {
        return page
            .round()
            .clamp(0, _state.pages.isEmpty ? 0 : _state.pages.length - 1);
      }
    }
    if (_state.pages.isEmpty) return 0;
    return _state.currentPage.clamp(0, _state.pages.length - 1);
  }

  Chapter? _displayedChapter(ReaderProvider provider) {
    final index =
        _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
    if (index < 0 || index >= provider.chapters.length) return null;
    return provider.chapters[index];
  }

  void _saveProgressSync() {
    if (_token == null) return;
    final provider = _readerProvider;
    if (provider == null) return;
    final chapterIndex =
        _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
    final chapter = chapterIndex >= 0 && chapterIndex < provider.chapters.length
        ? provider.chapters[chapterIndex]
        : null;
    final pos = _getProgress();
    provider.saveProgress(
      _token!,
      chapterIndex: chapterIndex,
      chapterTitle: chapter?.title,
      pos: pos,
    );
    // 同步保存到本地
    _saveProgressLocal(chapterIndex, pos);
  }

  Future<void> _saveProgress({double? pos}) async {
    if (_token == null) return;
    final provider = context.read<ReaderProvider>();
    final chapter = _displayedChapter(provider);
    final chapterIndex =
        _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
    final savePos = pos ?? _getProgress();

    // 保存到远端
    await provider.saveProgress(
      _token!,
      chapterIndex: chapterIndex,
      chapterTitle: chapter?.title,
      pos: savePos,
    );

    // 同时保存到本地（确保页级进度不丢失）
    _saveProgressLocal(chapterIndex, savePos);
  }

  /// 保存阅读进度到本地 SharedPreferences
  void _saveProgressLocal(int chapterIndex, double pos) {
    if (_bookUrl == null) return;
    final encodedUrl = _bookUrl!.replaceAll('/', '_').replaceAll(':', '_');
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('$_keyProgressChapterPrefix$encodedUrl', chapterIndex);
      prefs.setDouble('$_keyProgressPosPrefix$encodedUrl', pos);
    });
  }

  /// 从本地读取阅读进度
  Future<int?> _loadProgressLocalChapter() async {
    if (_bookUrl == null) return null;
    final encodedUrl = _bookUrl!.replaceAll('/', '_').replaceAll(':', '_');
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_keyProgressChapterPrefix$encodedUrl');
  }

  Future<double?> _loadProgressLocalPos() async {
    if (_bookUrl == null) return null;
    final encodedUrl = _bookUrl!.replaceAll('/', '_').replaceAll(':', '_');
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('$_keyProgressPosPrefix$encodedUrl');
  }

  // ============================================================
  // 章节加载
  // ============================================================

  /// 「替换净化」规则在**别处**变了（设置页改规则 / 换执行端 / 切总开关）。
  ///
  /// 【为什么页面这一层也要听】`ReaderProvider` 那边清的是它自己的预取缓存和
  /// 磁盘缓存；而**排版缓存**（`ReaderState.layoutCache` + 预排版结果）挂在
  /// 页面自己身上，Provider 够不着。不重排的话，用户改完规则回来，正文段落
  /// 还是旧规则切出来的 —— 表现就是「改了没生效，得点一下刷新」。
  ///
  /// 【为什么不能直接复用 [_onReplaceRuleChanged]】那个方法会**回头再拉一次
  /// 服务端规则**。可这条路径本身就是「规则刚变」触发的，拉回来会把本地因超时
  /// 停用过的规则重新启用 → 指纹再变 → 再发通知 → 死循环。
  /// 所以这里走 [refreshRules] = false 的轻量分支。
  void _onReplaceRulesChanged() {
    if (!mounted) return;
    _invalidateLayoutCaches();
    setState(() {});
    unawaited(_refreshChapterForRuleChange());
  }

  /// 规则变了之后重取当前章（**不再回头拉规则**，理由见 [_onReplaceRulesChanged]）。
  Future<void> _refreshChapterForRuleChange() async {
    final provider = _readerProvider;
    if (provider == null || !mounted || _token == null) return;
    await provider.invalidateChapterCacheAfterReplaceRuleChange(
      refreshRules: false,
    );
    if (!mounted) return;
    await _openChapter(
      _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
      chapterPosition: _state.chapterPosition,
    );
  }

  /// 把「按当前规则算出来的」排版结果全部作废。
  void _invalidateLayoutCaches() {
    _state.layoutCache.clear();
    _state.prefetchedNextLayout = null;
    _state.prefetchedNextChapterIndex = -1;
    _state.prefetchedPrevLayout = null;
    _state.prefetchedPrevChapterIndex = -1;
  }

  /// 「过滤」写入规则后调用：作废本地章节缓存，再重取当前章。
  ///
  /// 【为什么必须这么做】
  /// `ReaderProvider.getChapterContent` 命中缓存就直接返回。走**服务端净化**
  /// 时缓存目录只有 `replace_on` / `replace_off` 两级、**不带规则版本**，
  /// 所以加规则之前缓存下来的正文里是没被替换过的文字 —— 用户点了「过滤」
  /// 却看到正文毫无变化，会以为功能坏了（实际规则早就生效，只是界面读的是旧缓存）。
  ///
  /// 走**本地净化**时目录名里带了规则指纹，本来就能自动作废；这里多刷一次是
  /// 为了顺手把**本地那份规则副本**也更新掉（「过滤」是直接写服务端的），
  /// 否则本地引擎还在拿旧规则净化，同样是「点了没反应」。
  Future<void> _onReplaceRuleChanged() async {
    final provider = _readerProvider;
    if (provider == null || !mounted) return;
    // 把 token 一起传下去：本地净化引擎用的是本地那份规则副本，而「过滤」是
    // 直接写到服务端的 —— 不在这里重新拉一次，本地引擎就还在拿旧规则净化。
    await provider.invalidateChapterCacheAfterReplaceRuleChange(
      accessToken: _token,
    );
    if (!mounted) return;
    // 预排版缓存里同样是「旧规则下」的正文，一并作废
    _invalidateLayoutCaches();
    setState(() {});
    await _openChapter(
      _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
      chapterPosition: _state.chapterPosition,
    );
  }

  Future<void> _openChapter(
    int chapterIndex, {
    int chapterPosition = 0,
    bool openAtEnd = false,
  }) async {
    final token = _token;
    if (token == null) return;
    final provider = context.read<ReaderProvider>();
    if (chapterIndex < 0 || chapterIndex >= provider.chapters.length) return;

    final requestSerial = ++_state.chapterRequestSerial;
    _state.pendingChapterPosition = openAtEnd ? null : chapterPosition;
    _state.pendingOpenChapterAtEnd = openAtEnd;

    // 检查是否已预排版——如果是，直接同步切换（零等待）
    ChapterLayout? preLayout;
    String? preContent;
    String? preTitle;

    if (_state.prefetchedNextChapterIndex == chapterIndex &&
        _state.prefetchedNextLayout != null) {
      preLayout = _state.prefetchedNextLayout;
      preContent = _state.prefetchedNextContent;
      preTitle = _state.prefetchedNextTitle;
    } else if (_state.prefetchedPrevChapterIndex == chapterIndex &&
        _state.prefetchedPrevLayout != null) {
      preLayout = _state.prefetchedPrevLayout;
      preContent = _state.prefetchedPrevContent;
      preTitle = _state.prefetchedPrevTitle;
    }

    ChapterLayout layout;
    String content;
    String? chapterTitle;

    if (preLayout != null && preContent != null) {
      // 使用预排版结果，跳过网络请求和排版计算
      layout = preLayout;
      content = preContent;
      chapterTitle = preTitle;
    } else {
      // 走完整的异步流程
      content = await provider.getChapterContent(token, chapterIndex);
      if (!mounted || requestSerial != _state.chapterRequestSerial) return;

      chapterTitle = chapterIndex < provider.chapters.length
          ? provider.chapters[chapterIndex].title
          : null;

      layout = _layoutChapter(
        content: content,
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        targetPosition: 0,
      );
    }

    // 解析目标位置
    final targetPosition = _state.resolveTargetChapterPosition(
      provider.book?.durChapterIndex ?? 0,
      provider.book?.durChapterPos?.round(),
    );

    // 用新排版结果计算目标页码
    final targetPage = _paginationEngine
        .pageIndexForPosition(layout.pages, targetPosition)
        .clamp(0, layout.pages.length - 1);
    final normalizedPosition =
        layout.pages.isEmpty ? 0 : layout.pages[targetPage].startPosition;

    // 先创建新 PageController，再 setState
    final oldController = _pageController;
    _pageController = PageController(initialPage: targetPage);

    // 一次性更新所有状态
    setState(() {
      _state.loadingDisplayedChapter = false;
      _state.displayedContent = content;
      _state.laidOutChapterIndex = chapterIndex;
      _state.paragraphs = layout.paragraphs;
      _state.pages = layout.pages;
      _state.paragraphPageLookup = layout.paragraphPageLookup;
      _state.currentLayout = layout;
      _state.currentPage = targetPage;
      _state.chapterPosition = normalizedPosition;
    });

    // dispose 旧 controller
    oldController.dispose();

    _paragraphKeys =
        List.generate(_state.paragraphs.length, (_) => GlobalKey());
    _state.consumePendingPosition();

    provider.book?.durChapterIndex = chapterIndex;
    provider.book?.durChapterTitle = chapterTitle ?? '';

    // 清除已使用的预排版缓存
    if (_state.prefetchedNextChapterIndex == chapterIndex) {
      _state.prefetchedNextLayout = null;
      _state.prefetchedNextContent = null;
      _state.prefetchedNextTitle = null;
      _state.prefetchedNextChapterIndex = -1;
    }
    if (_state.prefetchedPrevChapterIndex == chapterIndex) {
      _state.prefetchedPrevLayout = null;
      _state.prefetchedPrevContent = null;
      _state.prefetchedPrevTitle = null;
      _state.prefetchedPrevChapterIndex = -1;
    }

    // 后台预取上下章节
    await _prefetchNextChapter(token, chapterIndex);
    _prefetchPrevChapter(token, chapterIndex);

    if (_state.continueTtsOnNextChapter) {
      _state.continueTtsOnNextChapter = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_state.ttsReading) return;
        _prepareTtsParagraphs(_state.displayedContent);
        _speakParagraphAt(0);
      });
    }
  }

  /// 排版章节（使用新引擎）
  ChapterLayout _layoutChapter({
    required String content,
    required String? chapterTitle,
    required int chapterIndex,
    int targetPosition = 0,
  }) {
    final size = _state.pagedViewportSize ?? MediaQuery.of(context).size;
    final safeTop = _state.pagedViewportSize == null
        ? MediaQuery.of(context).padding.top
        : 0.0;
    final safeBottom = _state.pagedViewportSize == null
        ? MediaQuery.of(context).padding.bottom
        : 0.0;

    // 系统「字体大小」的缩放系数。渲染端的 Text 会自动应用它，分页端必须同步，
    // 否则断行和行高都会算错（详见下面 paginate 的注释）。
    final textScaler = MediaQuery.textScalerOf(context);

    final cacheKey = ChapterLayout.cacheKey(
      chapterIndex,
      content.hashCode,
      _state.fontSize,
      _state.lineHeight,
      size.width,
      size.height,
      _state.pageMode,
      fontFamily: _state.fontFamily,
      bold: _state.boldText,
      // 系统字号变化会改变断行结果，必须进 key，否则会命中旧排版
      textScale: textScaler.scale(1.0),
      // 内置字体没读完时量出来的是回退字体的行宽，断行会偏。
      // 把它也放进 key，字体就绪后自动重排（见 ReaderFont.fontsReady 的注释）。
      fontsReady: ReaderFont.fontsReady,
      hideTitle: _state.hideTitle,
      headerFooterDivider: _state.showHeaderFooterDivider,
    );

    if (_state.layoutCache.containsKey(cacheKey)) {
      return _state.layoutCache[cacheKey]!;
    }

    final layout = _paginationEngine.paginate(
      content: content,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      fontSize: _state.fontSize,
      lineHeight: _state.lineHeight,
      viewportSize: size,
      safeTop: safeTop,
      safeBottom: safeBottom,
      paragraphSpacing: _state.paragraphSpacing,
      firstLineIndent: _state.firstLineIndent,
      horizontalPadding: _state.horizontalPadding,
      topPadding: _state.topPadding,
      // 页脚要自己避开手势条（外层 SafeArea 已 bottom: false），
      // 渲染端走的是同一个 _readerFooterPadding()。
      bottomPadding: _readerFooterPadding(),
      showTopBar: _state.showTopBar,
      showBottomBar: _state.showBottomBar,
      hideTitle: _state.hideTitle,
      showHeaderFooterDivider: _state.showHeaderFooterDivider,
      fontFamily: _state.textFontFamily,
      fontWeight: _state.textFontWeight,
      // 渲染端的 Text 会自动应用 MediaQuery.textScalerOf(context)（也就是系统的
      // 「字体大小」设置），分页端不跟着缩放的话，行拆分和行高都会算错 ——
      // 表现就是正文每行被二次换行截断，且总高度溢出压住页脚的时间/电量。
      textScaler: textScaler,
    );

    _state.layoutCache[cacheKey] = layout;
    return layout;
  }

  Future<void> _prefetchNextChapter(String token, int chapterIndex) async {
    final provider = context.read<ReaderProvider>();
    final nextIndex = chapterIndex + 1;
    if (nextIndex >= provider.chapters.length) return;

    // 如果已经预排版过同一章节，跳过
    if (_state.prefetchedNextChapterIndex == nextIndex &&
        _state.prefetchedNextLayout != null) return;

    try {
      final content = await provider.getChapterContent(token, nextIndex);
      if (!mounted) return;

      final chapterTitle = nextIndex < provider.chapters.length
          ? provider.chapters[nextIndex].title
          : null;

      final layout = _layoutChapter(
        content: content,
        chapterTitle: chapterTitle,
        chapterIndex: nextIndex,
      );

      _state.prefetchedNextLayout = layout;
      _state.prefetchedNextContent = content;
      _state.prefetchedNextTitle = chapterTitle;
      _state.prefetchedNextChapterIndex = nextIndex;
    } catch (_) {
      _state.prefetchedNextLayout = null;
      _state.prefetchedNextChapterIndex = -1;
    }
  }

  Future<void> _prefetchPrevChapter(String token, int chapterIndex) async {
    final provider = context.read<ReaderProvider>();
    final prevIndex = chapterIndex - 1;
    if (prevIndex < 0) return;

    // 如果已经预排版过同一章节，跳过
    if (_state.prefetchedPrevChapterIndex == prevIndex &&
        _state.prefetchedPrevLayout != null) return;

    try {
      final content = await provider.getChapterContent(token, prevIndex);
      if (!mounted) return;

      final chapterTitle = prevIndex < provider.chapters.length
          ? provider.chapters[prevIndex].title
          : null;

      final layout = _layoutChapter(
        content: content,
        chapterTitle: chapterTitle,
        chapterIndex: prevIndex,
      );

      _state.prefetchedPrevLayout = layout;
      _state.prefetchedPrevContent = content;
      _state.prefetchedPrevTitle = chapterTitle;
      _state.prefetchedPrevChapterIndex = prevIndex;
    } catch (_) {
      _state.prefetchedPrevLayout = null;
      _state.prefetchedPrevChapterIndex = -1;
    }
  }

  // ============================================================
  // 翻页
  // ============================================================

  /// 「上滑退出 / 下滑书签」（更多设置里的手势开关）。
  ///
  /// 只有分页模式能走到这里（滚动/漫画的竖向拖动归 ListView）。
  /// 阈值取 400 逻辑像素/秒，轻扫不会触发，得是明确的一甩。
  void _handleContentVerticalDrag(
      DragEndDetails details, ReaderProvider provider) {
    final velocity = details.primaryVelocity ?? 0;
    _refreshWakelockTimer();
    if (velocity <= -400 && _state.swipeUpExit) {
      // 和点控制栏「返回」同一条路径：先存进度再退出
      _saveProgress(pos: _getProgress());
      Navigator.pop(context);
      return;
    }
    if (velocity >= 400 && _state.swipeDownBookmark) {
      _toggleBookmark(provider);
    }
  }

  void _handleTap(TapUpDetails details, ReaderProvider provider) {
    // 点击 = 用户还醒着，刷新「屏幕常亮」档位倒计时
    _refreshWakelockTimer();
    // 有文字被选中时，单击只用来「取消选中」。
    // 否则用户点空白处想收起选区，页面却先翻走了。
    if (_hasSelection) {
      _hasSelection = false;
      _selectedText = '';
      _selectionState?.clearSelection();
      return;
    }

    if (_state.autoPageRunning) {
      // 自动翻页控制条也是「点一下出来、过几秒自己收」，别再常驻
      if (_state.showAutoPageControls) {
        _autoPageBarTimer?.cancel();
        setState(() => _state.showAutoPageControls = false);
      } else {
        _showAutoPageBar();
      }
      return;
    }

    final width = MediaQuery.of(context).size.width;

    if (_state.pageAnimType.usesScrollReader) {
      _toggleController();
      return;
    }

    if (width > 0 && details.globalPosition.dx < width / 3) {
      _previousPage(provider);
    } else if (width > 0 && details.globalPosition.dx > width * 2 / 3) {
      _nextPage(provider);
    } else {
      _toggleController();
    }
    // 控制栏正显示着的时候翻页，把自动隐藏倒计时往后推，
    // 免得用户连翻几页时工具条在半路被收走
    if (_state.showController) _restartControllerHideTimer();
  }

  /// 书内全文搜索点中某条结果后跳过去。
  ///
  /// `charOffset` 是「该章纯文本里的字符位置」，而 `_openChapter` 的
  /// `chapterPosition` 用的是同一套字符坐标（分页引擎的
  /// `PageSlice.startPosition` 就是字符下标），所以直接传即可。
  Future<void> _jumpToSearchResult(int chapterIndex, int charOffset) {
    return _openChapter(chapterIndex, chapterPosition: charOffset);
  }

  Duration _pageTurnDuration() {
    switch (_state.pageAnimType) {
      case PageAnimType.slide:
        return const Duration(milliseconds: 240);
      case PageAnimType.simulation:
        return const Duration(milliseconds: 320);
      case PageAnimType.flipbook:
        return const Duration(milliseconds: 340);
      case PageAnimType.none:
        return Duration.zero;
      case PageAnimType.cover:
      case PageAnimType.scroll:
        return const Duration(milliseconds: 220);
    }
  }

  Curve _pageTurnCurve() {
    switch (_state.pageAnimType) {
      case PageAnimType.cover:
        return Curves.easeOutCubic;
      case PageAnimType.slide:
        return Curves.easeOut;
      case PageAnimType.simulation:
        return Curves.easeInOutCubic;
      case PageAnimType.flipbook:
        return Curves.easeInOutCubic;
      case PageAnimType.scroll:
      case PageAnimType.none:
        return Curves.easeOut;
    }
  }

  void _moveToPage(int pageIndex) {
    // 翻页 = 用户还醒着，刷新「屏幕常亮」档位倒计时
    _refreshWakelockTimer();
    if (_state.pageAnimType.usesManualPaging) {
      if (_state.pageAnimType.instantTurn) {
        _pagedReaderController.jumpToPage(pageIndex);
      } else {
        _pagedReaderController.animateToPage(pageIndex);
      }
      return;
    }
    if (!_pageController.hasClients) return;
    if (_state.pageAnimType.instantTurn) {
      _pageController.jumpToPage(pageIndex);
      return;
    }
    _pageController.animateToPage(
      pageIndex,
      duration: _pageTurnDuration(),
      curve: _pageTurnCurve(),
    );
  }

  void _previousPage(ReaderProvider provider) {
    if (_state.pages.isEmpty) return;
    final currentPage = _activePageIndex();
    if (currentPage > 0) {
      _moveToPage(currentPage - 1);
    } else {
      final chapterIndex =
          _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
      if (chapterIndex <= 0) return;
      _saveProgress(pos: _state.chapterPosition.toDouble());
      // 如果上一章已预排版，直接同步切换（零等待）
      if (_state.prefetchedPrevChapterIndex == chapterIndex - 1 &&
          _state.prefetchedPrevLayout != null) {
        _switchToPrevChapter();
      } else {
        _openChapter(chapterIndex - 1, openAtEnd: true);
      }
    }
  }

  void _nextPage(ReaderProvider provider) {
    if (_state.pages.isEmpty) return;
    final currentPage = _activePageIndex();
    if (currentPage < _state.pages.length - 1) {
      _moveToPage(currentPage + 1);
    } else if (_state.autoNext) {
      final chapterIndex =
          _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
      if (chapterIndex >= provider.chapters.length - 1) {
        // 提示「已到本章末页」时把控制栏亮出来（并开始自动隐藏倒计时）
        _showControllerTemporarily();
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已到本章末页'),
            duration: Duration(seconds: 1),
          ),
        );
        return;
      }
      _saveProgress(pos: _state.chapterPosition.toDouble());
      // 如果下一章已预排版，直接同步切换（零等待）
      if (_state.prefetchedNextChapterIndex == chapterIndex + 1 &&
          _state.prefetchedNextLayout != null) {
        _switchToNextChapter();
      } else {
        _openChapter(chapterIndex + 1, chapterPosition: 0);
      }
    } else {
      _showControllerTemporarily();
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已到本章末页'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// 使用预排版结果同步切换到下一章（零等待）
  void _switchToNextChapter() {
    final layout = _state.prefetchedNextLayout!;
    final content = _state.prefetchedNextContent!;
    final chapterTitle = _state.prefetchedNextTitle;
    final chapterIndex = _state.prefetchedNextChapterIndex;

    const targetPage = 0; // 下一章从首页开始
    final normalizedPosition =
        layout.pages.isEmpty ? 0 : layout.pages[targetPage].startPosition;

    // 当前章节变成"上一章"的预排版
    _state.prefetchedPrevLayout = _state.currentLayout;
    _state.prefetchedPrevContent = _state.displayedContent;
    _state.prefetchedPrevTitle =
        _displayedChapter(context.read<ReaderProvider>())?.title;
    _state.prefetchedPrevChapterIndex = _state.laidOutChapterIndex;

    // 清除下一章预排版（需要在后台重新预取）
    _state.prefetchedNextLayout = null;
    _state.prefetchedNextContent = null;
    _state.prefetchedNextTitle = null;
    _state.prefetchedNextChapterIndex = -1;

    // 创建新 PageController
    final oldController = _pageController;
    _pageController = PageController(initialPage: targetPage);

    setState(() {
      _state.loadingDisplayedChapter = false;
      _state.displayedContent = content;
      _state.laidOutChapterIndex = chapterIndex;
      _state.paragraphs = layout.paragraphs;
      _state.pages = layout.pages;
      _state.paragraphPageLookup = layout.paragraphPageLookup;
      _state.currentLayout = layout;
      _state.currentPage = targetPage;
      _state.chapterPosition = normalizedPosition;
    });

    oldController.dispose();
    _paragraphKeys =
        List.generate(_state.paragraphs.length, (_) => GlobalKey());

    final provider = context.read<ReaderProvider>();
    provider.book?.durChapterIndex = chapterIndex;
    provider.book?.durChapterTitle = chapterTitle ?? '';

    // 后台预取新的下一章
    if (_token != null) {
      _prefetchNextChapter(_token!, chapterIndex);
    }
  }

  /// 使用预排版结果同步切换到上一章（零等待）
  void _switchToPrevChapter() {
    final layout = _state.prefetchedPrevLayout!;
    final content = _state.prefetchedPrevContent!;
    final chapterTitle = _state.prefetchedPrevTitle;
    final chapterIndex = _state.prefetchedPrevChapterIndex;

    final targetPage = layout.pages.length - 1; // 上一章从末页开始
    final normalizedPosition =
        layout.pages.isEmpty ? 0 : layout.pages[targetPage].startPosition;

    // 当前章节变成"下一章"的预排版
    _state.prefetchedNextLayout = _state.currentLayout;
    _state.prefetchedNextContent = _state.displayedContent;
    _state.prefetchedNextTitle =
        _displayedChapter(context.read<ReaderProvider>())?.title;
    _state.prefetchedNextChapterIndex = _state.laidOutChapterIndex;

    // 清除上一章预排版（需要在后台重新预取）
    _state.prefetchedPrevLayout = null;
    _state.prefetchedPrevContent = null;
    _state.prefetchedPrevTitle = null;
    _state.prefetchedPrevChapterIndex = -1;

    // 创建新 PageController
    final oldController = _pageController;
    _pageController = PageController(initialPage: targetPage);

    setState(() {
      _state.loadingDisplayedChapter = false;
      _state.displayedContent = content;
      _state.laidOutChapterIndex = chapterIndex;
      _state.paragraphs = layout.paragraphs;
      _state.pages = layout.pages;
      _state.paragraphPageLookup = layout.paragraphPageLookup;
      _state.currentLayout = layout;
      _state.currentPage = targetPage;
      _state.chapterPosition = normalizedPosition;
    });

    oldController.dispose();
    _paragraphKeys =
        List.generate(_state.paragraphs.length, (_) => GlobalKey());

    final provider = context.read<ReaderProvider>();
    provider.book?.durChapterIndex = chapterIndex;
    provider.book?.durChapterTitle = chapterTitle ?? '';

    // 后台预取新的上一章
    if (_token != null) {
      _prefetchPrevChapter(_token!, chapterIndex);
    }
  }

  void _toggleController() {
    if (_state.autoPageRunning) {
      if (_state.showAutoPageControls) {
        _autoPageBarTimer?.cancel();
        setState(() => _state.showAutoPageControls = false);
      } else {
        _showAutoPageBar();
      }
      return;
    }
    // 已经显示 → 手动收起（并取消倒计时）；没显示 → 显示并开始倒计时
    if (_state.showController) {
      _hideController();
    } else {
      _showControllerTemporarily();
    }
  }

  /// 显示控制栏，并开始自动隐藏倒计时
  void _showControllerTemporarily() {
    if (!_state.showController) {
      setState(() => _state.showController = true);
    }
    _restartControllerHideTimer();
  }

  /// 立刻收起控制栏（手动收起、或弹出面板要腾地方时调用）
  void _hideController() {
    _controllerHideTimer?.cancel();
    _controllerHideTimer = null;
    if (_state.showController) {
      setState(() => _state.showController = false);
    }
  }

  /// 重置自动隐藏倒计时。
  ///
  /// 在控制栏上做任何操作（翻章、拉进度、点目录…）都该调一次，
  /// 否则用户操作到一半工具条就被收走了。
  void _restartControllerHideTimer() {
    // 自动翻页模式下控制栏里有「秒/页」调节，需要常驻，不参与自动隐藏
    if (!_state.showController || _state.autoPageRunning) return;
    // 兜底倒计时（另一条在 ControllerOverlay 自己身上，见字段注释）
    _controllerHideTimer?.cancel();
    _controllerHideTimer = Timer(_controllerAutoHideDelay, () {
      if (!mounted) return;
      _hideController();
    });
    setState(() => _controllerRestartToken++);
  }

  /// 自动翻页控制条的自动隐藏（对齐控制栏：4 秒后收起来，点屏幕再出来）
  void _restartAutoPageBarTimer() {
    _autoPageBarTimer?.cancel();
    if (!_state.autoPageRunning || !_state.showAutoPageControls) return;
    _autoPageBarTimer = Timer(_autoPageBarHideDelay, () {
      if (!mounted) return;
      setState(() => _state.showAutoPageControls = false);
    });
  }

  void _showAutoPageBar() {
    if (!_state.showAutoPageControls) {
      setState(() => _state.showAutoPageControls = true);
    }
    _restartAutoPageBarTimer();
  }

  void _goToPreviousChapter() {
    final provider = context.read<ReaderProvider>();
    final chapterIndex =
        _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
    if (chapterIndex <= 0) return;
    _saveProgress(pos: _getProgress());
    _openChapter(chapterIndex - 1, openAtEnd: true);
  }

  void _goToNextChapter() {
    final provider = context.read<ReaderProvider>();
    final chapterIndex =
        _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
    if (chapterIndex >= provider.chapters.length - 1) return;
    _saveProgress(pos: _getProgress());
    _openChapter(chapterIndex + 1, chapterPosition: 0);
  }

  // ============================================================
  // 内容构建
  // ============================================================

  /// 给阅读页套一层系统栏样式：底部系统手势条跟阅读背景同色。
  ///
  /// 阅读页没有 AppBar，不会自带 `SystemUiOverlayStyle`；全局兜底给的是
  /// 浅色主题的白，在黑色 / 护眼绿主题下就会露出一条白边。
  Widget _withReaderSystemBars(Widget child) {
    final bg = _state.currentTheme.background;
    final bgBrightness = ThemeData.estimateBrightnessForColor(bg);
    final iconBrightness = bgBrightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        statusBarBrightness: bgBrightness,
        systemNavigationBarColor: bg,
        systemNavigationBarIconBrightness: iconBrightness,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _withReaderSystemBars(
      // 【为什么要把 letterSpacing 钉成 0】
      //
      // `Material` 会用 `theme.textTheme.bodyMedium` 当 `DefaultTextStyle`
      // 注入给整棵子树，而 Material 3 的 bodyMedium 自带 `letterSpacing: 0.25`。
      // `Text` 的 style 默认 `inherit: true`，会把这个 0.25 合并进去 ——
      // 于是**渲染端**每行实际比测量宽了「0.25 × 每行字数 ≈ 4px」。
      //
      // 而分页引擎用的是裸 `TextStyle`（letterSpacing 为 null，等于 0），
      // 它算「这一行刚好放得下」，渲染端却因为多出这 4px 把**行尾最后一个字
      // 挤到下一行** —— 页面上就会出现孤零零一个字占一行的「分段错误」。
      // 用「谷歌」字体时最明显，因为那个字体的字宽刚好卡在边界上。
      //
      // 在阅读页顶层把它归零，渲染端和分页端的度量就完全一致了。
      DefaultTextStyle.merge(
        style: const TextStyle(letterSpacing: 0),
        child: Scaffold(
          backgroundColor: _state.currentTheme.background,
          body: Consumer<ReaderProvider>(
            builder: (context, provider, _) {
              if (provider.book == null) {
                return const Center(child: Text('未选择书籍'));
              }
              return Stack(
                children: [
                  Positioned.fill(
                    // 【选中文字：SelectionArea 在外，GestureDetector 在内】
                    //
                    // 手势竞技场里 hit test 是「从内层往外层」收集识别器的，
                    // 所以内层的 GestureDetector 会先拿到单击 —— 单击翻页 /
                    // 唤出控制栏的行为**不受影响**。
                    //
                    // 长按则归 SelectionArea：它注册的是 LongPress，长按一旦
                    // 触发就赢得竞技场，「长按选中 + 拖拽调整手柄」可用；
                    // 未长按的水平拖动同理仍归 PagedReader 的 HorizontalDrag。
                    //
                    // 反过来写（GestureDetector 在外）会让单击被 SelectionArea
                    // 吃掉（它拿单击来清除选区），翻页直接失效。
                    child: SelectionArea(
                      // 记下选中的文字与选区状态：
                      //   - 选区存在时，单击只「取消选中」、不翻页；
                      //   - 选中菜单（复制/字典/过滤/搜索）要拿这段文字。
                      // SelectableRegionState 没有公开的取文本方法，只能从这里拿。
                      onSelectionChanged: (content) {
                        final text = content?.plainText.trim() ?? '';
                        _selectedText = text;
                        _hasSelection = text.isNotEmpty;
                      },
                      contextMenuBuilder: (ctx, selectionState) {
                        _selectionState = selectionState;
                        return ReaderSelectionMenu.build(
                          context: ctx,
                          state: selectionState,
                          selectedText: () => _selectedText,
                          book: provider.book!,
                          accessToken: _token ?? '',
                          chapters: provider.chapters,
                          loadChapterText: (index) =>
                              provider.peekChapterContent(_token ?? '', index),
                          onJumpToResult: _jumpToSearchResult,
                          onRuleChanged: _onReplaceRuleChanged,
                        );
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => _handleTap(details, provider),
                        // 「上滑退出 / 下滑书签」（更多设置）。
                        // 滚动/漫画模式的竖向拖动归内部 ListView，这个识别器
                        // 赢不了竞技场，天然不会误触发；分页模式（含左右滑的
                        // PageView）竖向没人认领，才会走到这里。
                        onVerticalDragEnd:
                            (_state.swipeUpExit || _state.swipeDownBookmark)
                                ? (details) =>
                                    _handleContentVerticalDrag(details, provider)
                                : null,
                        child: _buildContent(provider),
                      ),
                    ),
                  ),
                  // 亮度：盖一层黑色蒙版（不动系统亮度），只压暗正文区
                  if (_state.dimOpacity > 0)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color:
                              Colors.black.withValues(alpha: _state.dimOpacity),
                        ),
                      ),
                    ),
                if (_state.showController) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _toggleController,
                      child: Container(color: Colors.black.withValues(alpha: 0.18)),
                    ),
                  ),
                  ControllerOverlay(
                    // 控制栏的底色/文字色跟随当前阅读主题
                    // （原来是写死的黑色半透明，在浅色主题下会糊住正文）
                    theme: _state.currentTheme,
                    // 自动隐藏：自动翻页模式下传 null（控制栏常驻），
                    // 其余模式 4 秒后自动收起
                    autoHideDelay: _state.autoPageRunning
                        ? null
                        : _controllerAutoHideDelay,
                    restartToken: _controllerRestartToken,
                    onAutoHide: _hideController,
                    data: ReaderControllerViewData(
                      capsuleMode: _state.capsuleMode,
                      ttsState: _tts.state,
                      ttsRate: _tts.rate,
                      chapterIndex: _state.displayedChapterIndex(
                          provider.book?.durChapterIndex ?? 0),
                      totalChapters: provider.chapters.length,
                      chapterSliderValue: _state.chapterSliderValue,
                      // 「菜单滑动条按分页」：只在分页模式且已排出页时有意义
                      sliderByPage: _state.sliderByPage &&
                          !_state.isScrollMode &&
                          _state.pages.isNotEmpty,
                      currentPage: _state.currentPage,
                      totalPages: _state.pages.length,
                      pageSliderValue: _state.pageSliderValue,
                    ),
                    callbacks: ReaderControllerCallbacks(
                      onBack: () {
                        _saveProgress(pos: _getProgress());
                        Navigator.pop(context);
                      },
                      onBatchDownload: () => _showBatchDownloadSheet(provider),
                      onChangeSource: () => _changeBookSource(provider),
                      onRefresh: _applyReplaceRules,
                      onShowMore: () => _showMorePanel(provider),
                      onStartAutoPage: _startAutoPageMode,
                      onStartTts: _startTts,
                      onToggleTheme: _toggleNightMode,
                      onPrevChapter: _goToPreviousChapter,
                      onNextChapter: _goToNextChapter,
                      onChapterSliderChanged: (value) {
                        setState(() => _state.chapterSliderValue = value);
                      },
                      onChapterSliderEnd: (value) {
                        setState(() => _state.chapterSliderValue = null);
                        final target = value.round();
                        final ci = _state.displayedChapterIndex(
                            provider.book?.durChapterIndex ?? 0);
                        if (target != ci && _token != null) {
                          _saveProgress(pos: _getProgress());
                          _openChapter(target, chapterPosition: 0);
                        }
                      },
                      // 分页滑杆（「按分页」模式）：拖动只记瞬时值，松手跳页。
                      // 左右箭头也走这里（直接提交目标页）。
                      onPageSliderChanged: (value) {
                        setState(() => _state.pageSliderValue = value);
                      },
                      onPageSliderEnd: (value) {
                        setState(() => _state.pageSliderValue = null);
                        if (_state.pages.isEmpty) return;
                        final target =
                            value.round().clamp(0, _state.pages.length - 1);
                        if (target != _activePageIndex()) {
                          _moveToPage(target);
                        }
                      },
                      onShowChapterList: () => _showChapterList(provider),
                      onShowSettings: () => _showReadingSettingsSheet(provider),
                      onShowBackground: _showBackgroundSheet,
                      onShowMoreSettings: _showMoreSettingsPage,
                      onStopTts: _stopTts,
                      onPauseTts: _pauseTts,
                      onResumeTts: _resumeTts,
                      onShowTtsTimer: _showTtsTimerSheet,
                      onShowTtsSettings: _showTtsSettingsSheet,
                      // 朗读栏上的 ⏮ / ⏭ / « / » / 语速
                      onTtsPrevParagraph: () => _ttsSkipParagraph(-1),
                      onTtsNextParagraph: () => _ttsSkipParagraph(1),
                      onTtsPrevChapter: () => _ttsSwitchChapter(-1),
                      onTtsNextChapter: () => _ttsSwitchChapter(1),
                      onTtsRateChanged: (v) async {
                        await _tts.setRate(v);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ],
                if (_state.autoPageRunning && _state.showAutoPageControls)
                  // 自动翻页条 —— 对齐轻阅时光：白色胶囊，
                  // 「翻页时间 Ns」+ 滑杆 + 「■ 停止」灰胶囊。
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: SafeArea(
                      top: false,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(40),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 12,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Text(
                              '翻页时间 ${_state.autoPageInterval.toStringAsFixed(0)}s',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF222222),
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: const Color(0xFF5EC8C0),
                                  thumbColor: const Color(0xFF5EC8C0),
                                  inactiveTrackColor:
                                      const Color(0xFFE3E5E8),
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7),
                                  overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14),
                                ),
                                child: Slider(
                                  value: _state.autoPageInterval
                                      .clamp(3.0, 60.0),
                                  min: 3,
                                  max: 60,
                                  onChanged: _setAutoPageInterval,
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: _stopAutoPageMode,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 7),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF2F3F5),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.stop,
                                        size: 14, color: Color(0xFF333333)),
                                    SizedBox(width: 4),
                                    Text('停止',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: Color(0xFF333333))),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ],
                );
              },
            ),
          ),
        ),
      );
  }

  Widget _buildContent(ReaderProvider provider) {
    final bg = _state.currentTheme.background;

    if (provider.loadingChapters && provider.chapters.isEmpty) {
      return ColoredBox(
        color: bg,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (provider.error != null && provider.chapters.isEmpty) {
      return ColoredBox(
        color: bg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(provider.error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _retry, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final bookType = provider.book?.type ?? 0;
    if (bookType == 1) return SafeArea(child: _buildAudioPlaceholder(provider));
    if (bookType == 3) return SafeArea(child: _buildFilePlaceholder());

    // 【bottom: false —— 别再为手势条留那 34px】
    // 原来这里是完整 SafeArea，底部会为系统手势条（iOS home indicator、
    // Android 手势导航）再让出一整条安全区，正文与页脚底部于是叠出
    // 「页脚 + 6px + 安全区(约34px)」≈ 40px 的空白，观感就是下面空一大块。
    // 关掉底部的安全区让正文一直铺到屏幕底，避让改由**页脚自己的下边距**负责 ——
    // 具体值见下面 _readerFooterPadding()，分页引擎和渲染端收的是同一个数，
    // 三边（排版/绘制/滚动）必须一致，否则最后一行会被裁掉或底下多出一块空白。
    // 顶部/左右仍然保留 —— 状态栏和刘海那一带是真不能压。
    return SafeArea(
      bottom: false,
      child: _state.loadingDisplayedChapter && _state.displayedContent.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : provider.error != null && _state.displayedContent.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '加载章节失败\n${provider.error}',
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                          onPressed: _retry, child: const Text('重试')),
                    ],
                  ),
                )
              : _state.isComic ||
                      PaginationEngine.needsHtmlRenderer(_state.displayedContent)
                  ? _buildComicContent(provider)
                  : _state.pageAnimType.usesScrollReader
                      ? _buildScrollNovelContent(provider)
                      : _buildPagedNovelContent(provider),
    );
  }

  /// 「最大宽度」设置换算出来的**左右额外留白**（逻辑像素，单侧）。
  ///
  /// 官方网页版在「阅读界面 → 间距设置」面板最下面是这一项：一个开关 + 一条
  /// 滑动条，默认开、默认 600。宽屏上一行太长很难读，把正文挤到中间就舒服很多。
  ///
  /// 【为什么窄屏不用管】手机上屏宽本来就小于 600，`(屏宽 - 600) / 2` 是负数，
  /// clamp 到 0 —— 和没加这个设置时**完全一致**。所以手机和浏览器可以共用
  /// 同一个值，不需要按平台分支。
  ///
  /// 【为什么三种内容模式都走这里】漫画 / 滚动 / 分页各有一套排版，如果各写
  /// 一份同样的算式，哪天调了默认值或改了算法，很容易只改两处漏一处 ——
  /// 表现就是「某种翻页方式下最大宽度不生效」，极难排查。
  ///
  /// 注意算的是「额外」留白：正文两侧还要再加上用户自己的「左右边距」
  /// (`_state.horizontalPadding`)，所以最终正文宽度是
  /// `min(屏宽, 最大宽度) - 2 × 左右边距`，三种模式一致。
  double _readerSideExtra() {
    final settings = AppSettings.instance;
    if (!settings.readerMaxWidthEnabled) return 0.0;
    final maxWidth = settings.readerMaxWidth.toDouble();
    return ((MediaQuery.of(context).size.width - maxWidth) / 2)
        .clamp(0.0, double.infinity)
        .toDouble();
  }

  /// 页脚（时间/页码/电量）底部的留白 —— 三种内容模式共用同一个数。
  ///
  /// 【为什么抽出来】`SafeArea(bottom: false)` 之后底部安全区不再由外层兜底，
  /// 页脚得自己避开系统手势条。而这个数必须**同时**被三处看到：
  /// 分页引擎（算每页能放几行）、ContentRenderer（真正画出来）、滚动/漫画模式
  /// 的页脚 Padding。任何一处用别的数，就会出现「最后一行被裁掉」或者
  /// 「正文底下凭空多一块空白」这种要对着像素找半天的 bug。
  ///
  /// 取值的推导见 [PaginationEngine.footerBottomPadding]：安全区减 20px，
  /// 让页脚尽量贴近屏幕底，同时不压住手势条。
  ///
  /// 用 `paddingOf` 而不是 `viewPaddingOf`：前者会被软键盘等临时遮挡扣掉，
  /// 后者不会。阅读页弹软键盘时（搜索正文）不需要为手势条留位，用 padding 更准。
  double _readerFooterPadding() {
    return PaginationEngine.footerBottomPadding(
        MediaQuery.paddingOf(context).bottom);
  }

  Widget _buildPagedNovelContent(ReaderProvider provider) {
    // 【最大宽度】Padding 必须在 LayoutBuilder **外面**。
    //
    // 这里的分页不是渲染时算的：外层 LayoutBuilder 把 constraints.maxWidth
    // 存进 `_state.pagedViewportSize`，`_rebuildPages` 按它把整章切成一页页，
    // `PagedReader` 只是把**已经排好版**的 page 画出来。
    //
    // 所以如果把 Padding 套在 LayoutBuilder 里面，constraints.maxWidth 永远是
    // 全屏宽 → 分页按全屏切 → 再被 Padding 挤窄 → 正文右侧直接被裁掉，
    // 而且拖动滑动条时尺寸没变、不会重新分页。
    // 套在外面之后，LayoutBuilder 看到的就是限宽后的宽度，分页与渲染一致，
    // 拖滑动条也会因为尺寸变化自动触发重新分页。
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _readerSideExtra()),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (_state.pagedViewportSize == null ||
              (_state.pagedViewportSize!.width - size.width).abs() > 1 ||
              (_state.pagedViewportSize!.height - size.height).abs() > 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _state.pagedViewportSize = size);
              _rebuildPages(provider);
            });
          }

          if (_state.pages.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          final chapterTitle = _displayedChapter(provider)?.title ??
              provider.book?.durChapterTitle ??
              '';

          // 左右留白已经由外面的 Padding 统一加过了，这里直接铺满限宽后的区域。
          // 注意：那块留白落在 PagedReader 的 GestureDetector 之外，点那里不翻页；
          // 中间正文区和它自己的左右点击区照常工作。
          return PagedReader(
            key: ValueKey('chapter_${_state.laidOutChapterIndex}'),
            pages: _state.pages,
            pageController: _pageController,
            manualController: _pagedReaderController,
            theme: _state.currentTheme,
            fontSize: _state.fontSize,
            lineHeight: _state.lineHeight,
            chapterTitle: chapterTitle,
            currentPage: _state.currentPage,
            totalPages: _state.pages.length,
            ttsParagraphIndex: _state.ttsParagraphIndex,
            timeLabel: _state.formatTime(),
            batteryLabel: _state.batteryLabel(),
            showTopBar: _state.showTopBar,
            showBottomBar: _state.showBottomBar,
            showPageNumber: _state.showPageNumber,
            horizontalPadding: _state.horizontalPadding,
            topPadding: _state.topPadding,
            // 页脚自己要避开系统手势条（外层 SafeArea 已 bottom: false）
            bottomPadding: _readerFooterPadding(),
            paragraphSpacing: _state.paragraphSpacing,
            firstLineIndent: _state.firstLineIndent,
            animType: _state.pageAnimType,
            fontFamily: _state.textFontFamily,
            fontWeight: _state.textFontWeight,
            onCommentTap:
                _state.showParagraphComment ? _openParagraphComment : null,
            titleAlign: _state.titleTextAlign,
            showHeaderFooterDivider: _state.showHeaderFooterDivider,
            showFooterTime: _state.showFooterTime,
            showFooterBattery: _state.showFooterBattery,
            bottomAlignLastPage: _state.bottomAlignLastPage,
            progressMode: _state.progressMode,
            chapterIndex: _state.laidOutChapterIndex,
            totalChapters: provider.chapters.length,
            imageUrlBuilder: _buildImageUrl,
            onImageTap: _openImageViewer,
            onPageChanged: (page) {
              final position =
                  _state.pages.isEmpty ? 0 : _state.pages[page].startPosition;
              setState(() {
                _state.currentPage = page;
                _state.chapterPosition = position;
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildScrollNovelContent(ReaderProvider provider) {
    if (_state.paragraphs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final chapterTitle = _displayedChapter(provider)?.title ??
        provider.book?.durChapterTitle ??
        '';

    return ScrollReader(
      paragraphs: _state.paragraphs,
      scrollController: _novelScrollController,
      theme: _state.currentTheme,
      fontSize: _state.fontSize,
      lineHeight: _state.lineHeight,
      chapterTitle: chapterTitle,
      ttsParagraphIndex: _state.ttsParagraphIndex,
      pageIndicator: _state.pageIndicatorLabel(
        chapterIndex: _state.laidOutChapterIndex,
        totalChapters: provider.chapters.length,
      ),
      timeLabel: _state.formatTime(),
      batteryLabel: _state.batteryLabel(),
      // 【最大宽度】ScrollReader 内部没有 LayoutBuilder，宽度完全由这里传进去的
      // horizontalPadding 决定，所以直接把额外留白并进去即可（和漫画模式同一套）。
      // 这个 Padding 同时套住了正文和底部状态栏，两者一起收窄，视觉上是一致的。
      horizontalPadding: _state.horizontalPadding + _readerSideExtra(),
      topPadding: _state.topPadding,
      bottomPadding: _readerFooterPadding(),
      paragraphSpacing: _state.paragraphSpacing,
      firstLineIndent: _state.firstLineIndent,
      fontFamily: _state.textFontFamily,
      fontWeight: _state.textFontWeight,
      onCommentTap:
          _state.showParagraphComment ? _openParagraphComment : null,
      titleAlign: _state.titleTextAlign,
      showHeaderFooterDivider: _state.showHeaderFooterDivider,
      showFooterTime: _state.showFooterTime,
      showFooterBattery: _state.showFooterBattery,
      imageUrlBuilder: _buildImageUrl,
      onImageTap: _openImageViewer,
    );
  }

  Widget _buildComicContent(ReaderProvider provider) {
    final isComic = _state.isComic;
    final textColor = _state.currentTheme.text;

    // 【关键】flutter_html 的 _HtmlParserState 只在 didChangeDependencies() 里跑
    // prepareTree(), 它**没有 didUpdateWidget** —— 也就是说光换 style 参数,
    // Html 不会重新计算样式, 一直用第一次解析出来的那棵树。
    // 这就是"字号滑块拖了完全没反应"的直接原因。
    // 修法: 用 key 把设置值编进去, 设置一变就强制重建整个 Html。
    // 各滑块的 divisions 已把取值离散化(字号 20 档/段间距 10 档...), 不会每帧换 key。
    final htmlSettingsKey = ValueKey<String>(
      'html|${_state.fontSize.toStringAsFixed(1)}'
      '|${_state.lineHeight.toStringAsFixed(1)}'
      '|${_state.paragraphSpacing.toStringAsFixed(1)}'
      '|${_state.theme}',
    );

    // 【最大宽度】宽屏上一行太长很难读，用左右 padding 把正文挤到中间。
    //
    // 为什么用 padding 而不是给正文包 Center + ConstrainedBox：这样只动这一处，
    // 背景色仍然是全宽的、底部状态栏也不受影响。
    //
    // 漫画不限制：图片本来就该铺满。
    final sideExtra = isComic ? 0.0 : _readerSideExtra();

    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _comicScrollController,
            // 左右/上方边距跟随设置 (原先硬编码 16 / 12)
            padding: isComic
                ? EdgeInsets.zero
                : EdgeInsets.fromLTRB(
                    _state.horizontalPadding + sideExtra,
                    _state.topPadding,
                    _state.horizontalPadding + sideExtra,
                    12),
            children: [
              Html(
                key: htmlSettingsKey,
                data: _proxyImages(_state.displayedContent),
                style: {
                  'body': Style(
                    margin: Margins.zero,
                    padding: HtmlPaddings.zero,
                    // 字号/行距/颜色挂在 body 上, 由 flutter_html 的
                    // Style.copyOnlyInherited() 往下继承 (html_parser.dart:324 调用)。
                    // 原先只设在 'p' 上 —— 正文不是 <p> 包裹时字号就完全不生效。
                    fontSize: FontSize(_state.fontSize),
                    lineHeight: LineHeight(_state.lineHeight),
                    color: textColor,
                  ),
                  // 段间距跟随设置 (原先硬编码 10)
                  'p': Style(
                    margin: Margins.only(bottom: _state.paragraphSpacing),
                  ),
                  'div': Style(
                    margin: Margins.only(bottom: _state.paragraphSpacing),
                  ),
                  'img': Style(
                    margin: isComic ? Margins.zero : Margins.only(bottom: 8),
                    width: isComic ? Width(double.infinity) : null,
                  ),
                },
              ),
            ],
          ),
        ),
        _buildComicFooter(provider),
      ],
    );
  }

  Widget _buildComicFooter(ReaderProvider provider) {
    final theme = _state.currentTheme;
    return Padding(
      // 原来硬编码 10，且依赖外层 SafeArea 兜住手势条；现在外层是
      // SafeArea(bottom: false)，这里得跟正文/滚动模式用同一个数。
      padding: EdgeInsets.fromLTRB(24, 0, 24, _readerFooterPadding()),
      child: Row(
        children: [
          Text(_state.formatTime(),
              style: TextStyle(fontSize: 11, color: theme.secondaryText)),
          const Spacer(),
          Text(_state.pageIndicatorLabel(),
              style: TextStyle(fontSize: 11, color: theme.secondaryText)),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.battery_std, size: 13, color: theme.secondaryText),
              const SizedBox(width: 4),
              Text(_state.batteryLabel(),
                  style: TextStyle(fontSize: 11, color: theme.secondaryText)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAudioPlaceholder(ReaderProvider provider) {
    final theme = _state.currentTheme;
    final displayedChapter = _displayedChapter(provider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _state.ttsReading ? Icons.multitrack_audio : Icons.headphones,
            size: 64,
            color:
                _state.ttsReading ? const Color(0xFF00A88F) : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text('有声书朗读',
              style: TextStyle(
                  color: theme.text,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            _state.ttsReading
                ? (displayedChapter?.title ?? '朗读中...')
                : '点击下方按钮开始朗读',
            style: TextStyle(color: theme.secondaryText, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (_state.ttsReading) ...[
            SizedBox(
              width: 250,
              child: LinearProgressIndicator(
                value: _state.paragraphs.isNotEmpty
                    ? ((_state.ttsParagraphIndex + 1) /
                            _state.paragraphs.length)
                        .clamp(0.0, 1.0)
                    : null,
                backgroundColor: theme.divider,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF00A88F)),
              ),
            ),
            const SizedBox(height: 24),
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_state.ttsReading) ...[
                IconButton(
                  icon: const Icon(Icons.stop, size: 32),
                  onPressed: _stopTts,
                  tooltip: '停止',
                ),
                const SizedBox(width: 24),
                IconButton(
                  icon: Icon(
                    _tts.state == TtsState.paused
                        ? Icons.play_arrow
                        : Icons.pause,
                    size: 40,
                  ),
                  onPressed:
                      _tts.state == TtsState.paused ? _resumeTts : _pauseTts,
                ),
              ] else
                IconButton(
                  icon: const Icon(Icons.play_arrow, size: 48),
                  onPressed: _startTts,
                  tooltip: '开始朗读',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilePlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('该书籍为文件类型',
              style: TextStyle(color: _state.currentTheme.text, fontSize: 16)),
          const SizedBox(height: 4),
          Text('请使用外部应用打开',
              style: TextStyle(
                  color: _state.currentTheme.secondaryText, fontSize: 14)),
        ],
      ),
    );
  }

  /// 正文插图的地址构造器：原始 src → 官方 `/imageDecode` 的完整地址。
  ///
  /// 需要 token / 书源 / 书本信息，只有阅读页拿得到，所以放在这里注入给
  /// 分页渲染器（PagedReader / ScrollReader）。
  ///
  /// 【book 传 Map，不传 json 串】我们走 GET，参数全在请求行上，后端
  /// smart-http 的请求行有长度上限（实测 8.3K 就 500 readBuffer overflow）。
  /// 交给 [ImageDecodeUrl.build] 按需裁剪，别在这里先序列化成一大坨。
  String _buildImageUrl(String src) {
    final token = _token;
    if (token == null || token.isEmpty) return src;
    final book = context.read<ReaderProvider>().book;
    return ApiService.instance.imageDecodeUrl(
      src,
      accessToken: token,
      bookSourceUrl: book?.origin ?? book?.originName,
      book: book?.toJson(),
    );
  }

  /// 把正文里的 `<img src>` 换成官方 `/imageDecode` 地址（HTML 渲染路径用）。
  ///
  /// 【为什么不是 /proxypng】官方客户端取正文图走的是 `POST /imageDecode`
  /// （见官方 main.dart.js 的 `b2U`），参数 `url` / `bookSourceUrl` /
  /// `header` / `book`。`/proxypng` 只「转发 + 缓存」、**不解密** ——
  /// 阅文系的插图（`aigcc.yuewen.com/imgChapter/...`）是加密的，直接转发
  /// 拿到的是乱码，表现就是「书源里有图，App 里一张都没有」。
  ///
  /// 【取 src 必须复用 PaginationEngine 那两支正则】书源的 src 里内嵌
  /// **未转义的双引号**：`src="URL,{"style":"FULL","type":"qd"}"`。
  /// 用 `[^"']+` 这种单支非贪婪写法会在内层引号处截断，只把 `URL,{` 替换掉，
  /// 标签里剩下 `"style":"FULL",...}">` 一截垃圾 —— 图片照样出不来。
  /// 分页路径已经按官方 `cto` 修好了，这里共用同一个实现。
  String _proxyImages(String html) {
    return html.replaceAllMapped(PaginationEngine.anyImgTag, (match) {
      final fullTag = match.group(0) ?? '';
      final src = (PaginationEngine.extractImgSrc(fullTag) ?? '').trim();
      if (src.isEmpty) return fullTag;
      // 段评气泡是内联 base64 SVG，不该也不能走 /imageDecode
      if (src.startsWith('data:')) return fullTag;
      final url = _buildImageUrl(src);
      if (url.isEmpty) return fullTag;
      return fullTag.replaceFirst(src, url);
    });
  }

  void _rebuildPages(ReaderProvider provider) {
    // 滚动模式没有「页」可排，但段落列表同样来自分页引擎
    // （正文顶部标题段的注入/隐藏），所以「隐藏标题」这类改动
    // 在滚动模式下也要重抽段落，否则设置要等切章才生效。
    if (_state.pageMode == 'scroll' &&
        !_state.isComic &&
        _state.displayedContent.isNotEmpty) {
      final scrollChapterTitle = _displayedChapter(provider)?.title ??
          provider.book?.durChapterTitle;
      final scrollLayout = _layoutChapter(
        content: _state.displayedContent,
        chapterTitle: scrollChapterTitle,
        chapterIndex: _state.laidOutChapterIndex,
      );
      setState(() {
        _state.paragraphs = scrollLayout.paragraphs;
        _paragraphKeys =
            List.generate(_state.paragraphs.length, (_) => GlobalKey());
      });
      return;
    }

    if (_state.pageMode != 'paged' ||
        _state.displayedContent.isEmpty ||
        _state.isComic ||
        PaginationEngine.needsHtmlRenderer(_state.displayedContent)) {
      return;
    }

    final targetPosition = _state.resolveTargetChapterPosition(
      provider.book?.durChapterIndex ?? 0,
      provider.book?.durChapterPos?.round(),
    );

    final chapterTitle =
        _displayedChapter(provider)?.title ?? provider.book?.durChapterTitle;

    final layout = _layoutChapter(
      content: _state.displayedContent,
      chapterTitle: chapterTitle,
      chapterIndex: _state.laidOutChapterIndex,
      targetPosition: targetPosition,
    );

    final targetPage = _paginationEngine
        .pageIndexForPosition(layout.pages, targetPosition)
        .clamp(0, layout.pages.length - 1);
    final normalizedPosition =
        layout.pages.isEmpty ? 0 : layout.pages[targetPage].startPosition;

    setState(() {
      _state.paragraphs = layout.paragraphs;
      _state.pages = layout.pages;
      _state.paragraphPageLookup = layout.paragraphPageLookup;
      _state.currentLayout = layout;
      _state.currentPage = targetPage;
      _state.chapterPosition = normalizedPosition;
    });

    _paragraphKeys =
        List.generate(_state.paragraphs.length, (_) => GlobalKey());
    // 先创建新 controller，再 dispose 旧的
    final oldCtrl = _pageController;
    _pageController = PageController(initialPage: targetPage);
    oldCtrl.dispose();
    _state.consumePendingPosition();
  }

  // ============================================================
  // 自动翻页
  // ============================================================

  void _startAutoPageMode() {
    final provider = context.read<ReaderProvider>();
    _stopTts();
    // 自动翻页模式下控制栏常驻，不需要自动隐藏倒计时。
    // 把 showController 置 false 后控制栏会从树上移除，它自带的倒计时
    // 也随之在 dispose 里被取消。
    setState(() {
      _state.autoPageRunning = true;
      _state.showAutoPageControls = true;
      _state.showController = false;
    });
    // 底部那条「自动翻页 / N 秒 / 停止」原来永远不会自己收起来
    // （用户反馈「屏幕底部的小横条还是自动无法隐藏」），这里补上自动隐藏：
    // 4 秒后收起，点屏幕再出来。
    _restartAutoPageBarTimer();
    _restartAutoPageTimer(provider);
  }

  void _restartAutoPageTimer(ReaderProvider provider) {
    _autoPageTimer?.cancel();
    _autoPageTimer = Timer.periodic(
      Duration(milliseconds: (_state.autoPageInterval * 1000).round()),
      (_) => _performAutoPageStep(provider),
    );
    _saveSettings();
  }

  void _performAutoPageStep(ReaderProvider provider) {
    if (!mounted) return;
    if (_state.isComic) {
      if (_comicScrollController.hasClients &&
          _comicScrollController.offset >=
              _comicScrollController.position.maxScrollExtent - 30) {
        if (_state.autoNext &&
            _state.hasNextChapter(
                _state
                    .displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
                provider.chapters.length)) {
          _goToNextChapter();
        } else {
          _stopAutoPageMode();
        }
      } else {
        _comicScrollDown();
      }
      return;
    }

    if (_state.pageAnimType.usesScrollReader) {
      if (!_novelScrollController.hasClients) return;
      final target = (_novelScrollController.offset +
              MediaQuery.of(context).size.height * 0.75)
          .clamp(0.0, _novelScrollController.position.maxScrollExtent);
      if (target >= _novelScrollController.position.maxScrollExtent - 20) {
        if (_state.autoNext &&
            _state.hasNextChapter(
                _state
                    .displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
                provider.chapters.length)) {
          _goToNextChapter();
        } else {
          _stopAutoPageMode();
        }
      } else {
        _novelScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      }
      return;
    }

    final wasLastPage = _activePageIndex() >= _state.pages.length - 1;
    _nextPage(provider);
    if (wasLastPage &&
        (!_state.hasNextChapter(
                _state
                    .displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
                provider.chapters.length) ||
            !_state.autoNext)) {
      _stopAutoPageMode();
    }
  }

  void _comicScrollDown() {
    if (!_comicScrollController.hasClients) return;
    final pageHeight = MediaQuery.of(context).size.height * 0.8;
    _comicScrollController.animateTo(
      (_comicScrollController.offset + pageHeight)
          .clamp(0.0, _comicScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _changeAutoPageInterval(double delta) {
    _setAutoPageInterval(_state.autoPageInterval + delta);
  }

  /// 直接设定自动翻页间隔（自动翻页条上的滑杆用）。
  void _setAutoPageInterval(double value) {
    final provider = context.read<ReaderProvider>();
    setState(() {
      _state.autoPageInterval = value.clamp(3.0, 60.0);
    });
    if (_state.autoPageRunning) {
      _restartAutoPageTimer(provider);
      // 调间隔也算一次交互，把控制条的自动隐藏往后推
      _restartAutoPageBarTimer();
    } else {
      _saveSettings();
    }
  }

  void _stopAutoPageMode() {
    _autoPageTimer?.cancel();
    _autoPageBarTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _state.autoPageRunning = false;
      _state.showAutoPageControls = true;
    });
  }

  /// 夜间切换：深色 ⇄ 切夜间之前的主题（对齐轻阅时光的「夜间」圆钮）。
  /// 之前的循环换肤（`_toggleReaderTheme` 走 nextTheme）已随旧胶囊一起移除 ——
  /// 换肤现在由「背景」面板里的色点负责。
  String? _themeBeforeNight;

  void _toggleNightMode() {
    setState(() {
      if (_state.theme == 'dark') {
        _state.theme = _themeBeforeNight ?? 'green';
        _themeBeforeNight = null;
      } else {
        _themeBeforeNight = _state.theme;
        _state.theme = 'dark';
      }
    });
    _saveSettings();
  }

  // ============================================================
  // TTS
  // ============================================================

  Future<void> _startTts() async {
    final text = _state.displayedContent;
    if (text.isEmpty) return;
    _stopAutoPageMode();
    _prepareTtsParagraphs(text);
    if (_state.paragraphs.isEmpty) return;

    // 找到当前页面第一个段落作为 TTS 起始位置
    int startParagraphIndex;
    if (_state.ttsParagraphIndex >= 0) {
      // 已有 TTS 位置，继续使用
      startParagraphIndex = _state.ttsParagraphIndex;
    } else if (_state.pages.isNotEmpty &&
        _state.currentPage < _state.pages.length) {
      // 从当前页面的第一个段落开始
      final currentPageLines = _state.pages[_state.currentPage].lines;
      startParagraphIndex = currentPageLines.isNotEmpty
          ? currentPageLines.first.paragraphIndex
          : 0;
    } else {
      startParagraphIndex = 0;
    }

    setState(() {
      _state.ttsReading = true;
      _state.continueTtsOnNextChapter = false;
      _state.showController = true;
    });
    // TTS 模式下控制栏里是停止/暂停按钮，同样会自动收起
    _restartControllerHideTimer();
    await _speakParagraphAt(startParagraphIndex);
  }

  void _prepareTtsParagraphs(String text) {
    if (_state.paragraphs.isNotEmpty) return;
    final layout = _paginationEngine.paginate(
      content: text,
      chapterTitle: null,
      chapterIndex: _state.laidOutChapterIndex,
      fontSize: _state.fontSize,
      lineHeight: _state.lineHeight,
      viewportSize: _state.pagedViewportSize ?? MediaQuery.of(context).size,
      safeTop: MediaQuery.of(context).padding.top,
      safeBottom: MediaQuery.of(context).padding.bottom,
      textScaler: MediaQuery.textScalerOf(context),
    );
    setState(() {
      _state.paragraphs = layout.paragraphs;
    });
    _paragraphKeys =
        List.generate(_state.paragraphs.length, (_) => GlobalKey());
  }

  Future<void> _speakParagraphAt(int index) async {
    if (!_state.ttsReading || index < 0 || index >= _state.paragraphs.length) {
      return;
    }
    setState(() => _state.ttsParagraphIndex = index);
    // 「延迟翻页」开启时，翻页交给上一段的 onChunkComplete（这一段读完了才翻），
    // 画面不会跑到朗读前面去；关掉就是段落一开始就紧跟高亮走。
    if (!_state.ttsDelayPageTurn) _focusParagraph(index);

    _tts.onChunkComplete = () {
      if (!_state.ttsReading || !mounted) return;
      final nextIndex = index + 1;
      if (nextIndex < _state.paragraphs.length) {
        if (_state.ttsDelayPageTurn) _focusParagraph(nextIndex);
        _speakParagraphAt(nextIndex);
        return;
      }
      final provider = context.read<ReaderProvider>();
      final ci =
          _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
      // 「显示章节切换」关掉后，本章读完就停，不再自动切下一章
      if (_state.ttsShowChapterSwitch &&
          _state.autoNext &&
          _state.hasNextChapter(ci, provider.chapters.length) &&
          _token != null) {
        _state.continueTtsOnNextChapter = true;
        _saveProgress(pos: 1.0);
        _openChapter(ci + 1, chapterPosition: 0);
      } else {
        _stopTts();
      }
    };

    await _tts.speakText(_state.paragraphs[index].text);
  }

  /// 朗读栏上的 ⏮ / ⏭：跳到上一段 / 下一段并接着读
  void _ttsSkipParagraph(int delta) {
    if (!_state.ttsReading || _state.paragraphs.isEmpty) return;
    final current =
        _state.ttsParagraphIndex < 0 ? 0 : _state.ttsParagraphIndex;
    final target = (current + delta).clamp(0, _state.paragraphs.length - 1);
    if (target == current) return;
    _speakParagraphAt(target);
  }

  /// 朗读栏上的 « / »：切上一章 / 下一章并接着读
  void _ttsSwitchChapter(int delta) {
    if (_state.ttsReading) _state.continueTtsOnNextChapter = true;
    if (delta < 0) {
      _goToPreviousChapter();
    } else {
      _goToNextChapter();
    }
  }

  void _focusParagraph(int index) {
    // 「允许听书翻页」关掉后，页面就停在原处，不再跟着朗读走
    if (!_state.ttsAllowPageTurn) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_state.pageAnimType.usesScrollReader) {
        final pageIndex = _state.paragraphPageLookup[index];
        if (pageIndex != null && pageIndex != _state.currentPage) {
          _moveToPage(pageIndex);
        }
        return;
      }
      if (index < 0 || index >= _paragraphKeys.length) return;
      final targetContext = _paragraphKeys[index].currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 220),
          alignment: 0.18,
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pauseTts() async {
    await _tts.pause();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _resumeTts() async {
    if (_state.ttsParagraphIndex < 0 && _state.paragraphs.isNotEmpty) {
      _state.ttsParagraphIndex = 0;
    }
    if (!_state.ttsReading) {
      setState(() => _state.ttsReading = true);
    }
    await _speakParagraphAt(
        _state.ttsParagraphIndex.clamp(0, _state.paragraphs.length - 1));
  }

  Future<void> _stopTts() async {
    _tts.onChunkComplete = null;
    _ttsSleepTimer?.cancel();
    await _tts.stop();
    if (!mounted) return;
    setState(() {
      _state.ttsReading = false;
      _state.continueTtsOnNextChapter = false;
      _state.ttsParagraphIndex = -1;
      _state.ttsSleepMinutes = null;
    });
  }

  // ============================================================
  // 书签
  // ============================================================

  Bookmark? _bookmarkAtCurrent(ReaderProvider provider) {
    final idx =
        _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
    for (final mark in _bookmarks) {
      if (mark.chapterIndex == idx && mark.chapterPos != null) return mark;
    }
    return null;
  }

  Future<void> _toggleBookmark(ReaderProvider provider) async {
    if (_token == null || _bookUrl == null) return;
    final existing = _bookmarkAtCurrent(provider);
    if (existing != null && existing.id != null) {
      try {
        await ApiService.instance.deleteBookmark(_token!, existing.id!);
        await _loadBookmarks();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书签已删除')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除书签失败: $e')),
        );
      }
      return;
    }
    try {
      final chapterName = _displayedChapter(provider)?.title ?? '';
      final index =
          _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
      final pos = _state.chapterPosition.toDouble();
      await ApiService.instance.addBookmark(
        _token!,
        url: _bookUrl!,
        name: chapterName,
        index: index,
        pos: pos,
      );
      await _loadBookmarks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书签已添加')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加书签失败: $e')),
      );
    }
  }

  // ============================================================
  // 底部弹窗
  // ============================================================

  /// 目录 / 书签 / 笔记弹层 —— 复用书籍详情页的 [BookTocSheet]（轻阅时光样式）。
  ///
  /// 弹层点章节/书签会返回 [ReaderLaunchArgs]，这里转成跳章。
  Future<void> _showChapterList(ReaderProvider provider) async {
    final book = provider.book;
    final token = _token;
    if (book == null || token == null) return;
    _hideController();
    final args = await showModalBottomSheet<ReaderLaunchArgs>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // 把 provider 已有的目录直接喂进去：弹层秒开，刷新由弹层后台做
      builder: (_) => BookTocSheet(
        book: book,
        token: token,
        initialChapters: provider.chapters,
        // 「更多设置 → 目录倒序」：弹层里的正序/倒序按钮改动后也回写设置
        initialAscending: !_state.tocReversed,
        onOrderChanged: (ascending) {
          setState(() => _state.tocReversed = !ascending);
          _saveSettings();
        },
      ),
    );
    if (args == null || !mounted) return;
    _saveProgress(pos: _getProgress());
    final index = args.chapterIndex ?? 0;
    if (index >= provider.chapters.length) {
      // 弹层后台刷新出的目录可能比 provider 这份多几章 —— 只有点到了
      // 越界下标才值得等一次刷新，常见情况（下标有效）直接跳，别卡网络。
      try {
        await provider.refreshChapters(token);
      } catch (_) {}
      if (!mounted) return;
    } else {
      // 顺手把 provider 的目录刷齐（下一章预取、滑杆总章数都吃这份），
      // 但不挡跳章。
      unawaited(provider.refreshChapters(token).catchError((_) => 0));
    }
    await _openChapter(
      index,
      chapterPosition: args.chapterPosition,
      openAtEnd: args.openAtEnd,
    );
  }


  /// 界面设置 —— 对齐轻阅时光：字号行（－ 数值 ＋ 更多）+ 字体行 + 间距/翻页两个宽按钮。
  ///
  /// 亮度与背景色挪去了「背景设置」面板（[_showBackgroundSheet]），
  /// 翻页动画列表挪去了「翻页设置」（[_showPageAnimSheet]），
  /// 这个面板只留排版相关的入口。
  void _showReadingSettingsSheet(ReaderProvider provider) {
    // 面板配色跟随阅读主题：面板底色就是正文背景色。
    final readerTheme = _state.currentTheme;
    // 轻阅时光的面板是纯白底 + 浅灰容器；深色主题下沿用主题底色，
    // 容器色用「文字色的极淡版」，避免深色主题里出现一块刺眼的白。
    final isDark = readerTheme.background.computeLuminance() < 0.5;
    final cardBg = isDark
        ? readerTheme.text.withValues(alpha: 0.08)
        : const Color(0xFFF5F6F8);
    final pillBg =
        isDark ? readerTheme.text.withValues(alpha: 0.14) : Colors.white;

    // 官方客户端里，设置面板一出来，顶部/底部工具条就收起来了。
    _hideController();

    showModalBottomSheet(
      context: context,
      backgroundColor: readerTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            void commit(VoidCallback fn, {bool rebuildPages = false}) {
              setState(fn);
              sheetSetState(() {});
              _saveSettings();
              if (rebuildPages) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _rebuildPages(context.read<ReaderProvider>());
                });
              }
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---- 标题 ----
                    Row(
                      children: [
                        Icon(Icons.tune, size: 20, color: readerTheme.text),
                        const SizedBox(width: 8),
                        Text('界面设置',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: readerTheme.text)),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // ---- 字号 ----
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.text_fields,
                              size: 18, color: readerTheme.text),
                          const SizedBox(width: 6),
                          Text('字号',
                              style: TextStyle(
                                  fontSize: 15, color: readerTheme.text)),
                          const Spacer(),
                          _uiSettingPill(
                            pillBg: pillBg,
                            textColor: readerTheme.text,
                            onTap: () {
                              final next =
                                  (_state.fontSize - 2).clamp(12.0, 40.0);
                              commit(() => _state.fontSize = next,
                                  rebuildPages: true);
                            },
                            child: Icon(Icons.remove,
                                size: 18, color: readerTheme.text),
                          ),
                          const SizedBox(width: 8),
                          _uiSettingPill(
                            pillBg: pillBg,
                            textColor: readerTheme.text,
                            child: Text(
                              '${_state.fontSize.round()}',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: readerTheme.text),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _uiSettingPill(
                            pillBg: pillBg,
                            textColor: readerTheme.text,
                            onTap: () {
                              final next =
                                  (_state.fontSize + 2).clamp(12.0, 40.0);
                              commit(() => _state.fontSize = next,
                                  rebuildPages: true);
                            },
                            child: Icon(Icons.add,
                                size: 18, color: readerTheme.text),
                          ),
                          const SizedBox(width: 8),
                          _uiSettingPill(
                            pillBg: pillBg,
                            textColor: readerTheme.text,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _showFontSizeMoreSheet(provider);
                            },
                            child: Text('更多',
                                style: TextStyle(
                                    fontSize: 14, color: readerTheme.text)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ---- 字体 ----
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.font_download_outlined,
                              size: 18, color: readerTheme.text),
                          const SizedBox(width: 6),
                          Text('字体',
                              style: TextStyle(
                                  fontSize: 15, color: readerTheme.text)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: _uiSettingPill(
                              pillBg: pillBg,
                              textColor: readerTheme.text,
                              height: 40,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                _showFontPickerSheet(provider);
                              },
                              child: Text(
                                ReaderFont.byId(_state.fontFamily).label,
                                style: TextStyle(
                                    fontSize: 14, color: readerTheme.text),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // ---- 间距设置 / 翻页设置 ----
                    Row(
                      children: [
                        Expanded(
                          child: _panelButton(
                            icon: Icons.format_line_spacing,
                            label: '间距设置',
                            textColor: readerTheme.text,
                            borderColor: readerTheme.divider,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _showSpacingSettingsSheet(provider);
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _panelButton(
                            icon: Icons.auto_stories_outlined,
                            label: '翻页设置',
                            textColor: readerTheme.text,
                            borderColor: readerTheme.divider,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _showPageAnimSheet(provider);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 界面设置面板里的小胶囊（－ / 数值 / ＋ / 更多 / 字体名）。
  Widget _uiSettingPill({
    required Color pillBg,
    required Color textColor,
    required Widget child,
    VoidCallback? onTap,
    double height = 34,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        constraints: const BoxConstraints(minWidth: 46),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: pillBg,
          borderRadius: BorderRadius.circular(9),
        ),
        child: child,
      ),
    );
  }

  /// 「字号 → 更多」：首行缩进 / 行高 / 粗体。
  ///
  /// 轻阅时光这里还有「简繁转换」「全局下划线」「字间距」「字重」，Qread 的排版
  /// 引擎没有这些管线，不放摆没反应的占位开关 —— 只留真生效的三项。
  void _showFontSizeMoreSheet(ReaderProvider provider) {
    final readerTheme = _state.currentTheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: readerTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            void commit(VoidCallback fn, {bool rebuildPages = false}) {
              setState(fn);
              sheetSetState(() {});
              _saveSettings();
              if (rebuildPages) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _rebuildPages(context.read<ReaderProvider>());
                });
              }
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('字号设置',
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: readerTheme.text)),
                        ),
                        IconButton(
                          icon: Icon(Icons.close,
                              size: 20, color: readerTheme.text),
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    _SettingRow(
                      label: '首行缩进',
                      value: _state.firstLineIndent.round().toString(),
                      child: Slider(
                        value: _state.firstLineIndent,
                        min: 0,
                        max: 4,
                        divisions: 4,
                        label: _state.firstLineIndent.round().toString(),
                        onChanged: (v) => commit(
                            () => _state.firstLineIndent = v,
                            rebuildPages: true),
                      ),
                    ),
                    _SettingRow(
                      label: '行高',
                      value: _state.lineHeight.toStringAsFixed(1),
                      child: Slider(
                        value: _state.lineHeight,
                        min: 1.2,
                        max: 2.6,
                        divisions: 14,
                        label: _state.lineHeight.toStringAsFixed(1),
                        onChanged: (v) => commit(() => _state.lineHeight = v,
                            rebuildPages: true),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('粗体',
                          style: TextStyle(
                              fontSize: 15, color: readerTheme.text)),
                      value: _state.boldText,
                      onChanged: (v) => commit(() => _state.boldText = v,
                          rebuildPages: true),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 「字体 → 选择字体」：每种字体用它自己的字形渲染标签（对齐轻阅时光）。
  void _showFontPickerSheet(ReaderProvider provider) {
    final readerTheme = _state.currentTheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: readerTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            void pick(String id) {
              setState(() => _state.fontFamily = id);
              sheetSetState(() {});
              _saveSettings();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _rebuildPages(context.read<ReaderProvider>());
              });
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('选择字体',
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: readerTheme.text)),
                        ),
                        IconButton(
                          icon: Icon(Icons.close,
                              size: 20, color: readerTheme.text),
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final font in ReaderFont.presets)
                          _fontChoiceChip(
                            font: font,
                            selected: _state.fontFamily == font.id,
                            theme: readerTheme,
                            onTap: () => pick(font.id),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _fontChoiceChip({
    required ReaderFont font,
    required bool selected,
    required ReaderTheme theme,
    required VoidCallback onTap,
  }) {
    const accent = Color(0xFF55A0E8);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.15)
              : theme.text.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          font.label,
          style: TextStyle(
            fontSize: 16,
            // 每个字体选项用自己的字族渲染，点之前就能看到长什么样。
            fontFamily: font.family,
            color: selected ? accent : theme.text,
          ),
        ),
      ),
    );
  }

  /// 「翻页设置」：翻页动画列表，选中项打勾（对齐轻阅时光的「翻页方式」）。
  void _showPageAnimSheet(ReaderProvider provider) {
    final readerTheme = _state.currentTheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: readerTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('翻页方式',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: readerTheme.text)),
                    ),
                    IconButton(
                      icon: Icon(Icons.close,
                          size: 20, color: readerTheme.text),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
              ),
              for (final anim in PageAnimType.primaryChoices)
                ListTile(
                  title: Text(anim.label,
                      style: TextStyle(fontSize: 15, color: readerTheme.text)),
                  trailing: _state.pageAnimType == anim
                      ? const Icon(Icons.check,
                          size: 20, color: Color(0xFF55A0E8))
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    setState(() => _state.applyPageAnimType(anim));
                    _saveSettings();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _rebuildPages(context.read<ReaderProvider>());
                      }
                    });
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  /// 背景设置 —— 对齐轻阅时光：亮度滑条（太阳图标 + 眼睛图标）+ 主题色圆点行。
  void _showBackgroundSheet() {
    final readerTheme = _state.currentTheme;
    const sliderAccent = Color(0xFF7CB7B2);

    _hideController();

    showModalBottomSheet(
      context: context,
      backgroundColor: readerTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            void commit(VoidCallback fn) {
              setState(fn);
              sheetSetState(() {});
              _saveSettings();
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---- 标题 ----
                    Row(
                      children: [
                        Icon(Icons.palette_outlined,
                            size: 20, color: readerTheme.text),
                        const SizedBox(width: 8),
                        Text('背景设置',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: readerTheme.text)),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // ---- 亮度 ----
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: readerTheme.text.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.wb_sunny_outlined,
                              size: 20, color: readerTheme.secondaryText),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: sliderAccent,
                                thumbColor: Colors.white,
                                inactiveTrackColor: readerTheme.divider,
                                trackHeight: 8,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 10),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 18),
                              ),
                              child: Slider(
                                // 自动档不压暗（见 ReaderState.brightnessAuto），
                                // 滑条停在最亮并禁用。
                                value: _state.brightnessAuto
                                    ? 1.0
                                    : _state.brightness.clamp(0.1, 1.0),
                                min: 0.1,
                                max: 1.0,
                                divisions: 18,
                                onChanged: _state.brightnessAuto
                                    ? null
                                    : (v) =>
                                        commit(() => _state.brightness = v),
                              ),
                            ),
                          ),
                          Icon(Icons.remove_red_eye_outlined,
                              size: 20, color: readerTheme.secondaryText),
                          const SizedBox(width: 8),
                          // 「自动」= 跟随系统亮度（不盖压暗蒙版）
                          GestureDetector(
                            onTap: () => commit(() =>
                                _state.brightnessAuto =
                                    !_state.brightnessAuto),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: _state.brightnessAuto
                                    ? sliderAccent
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: _state.brightnessAuto
                                      ? sliderAccent
                                      : readerTheme.secondaryText,
                                ),
                              ),
                              child: Text(
                                '自动',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _state.brightnessAuto
                                      ? Colors.white
                                      : readerTheme.secondaryText,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ---- 主题色 ----
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                      decoration: BoxDecoration(
                        color: readerTheme.text.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          for (final preset in ReaderTheme.presets)
                            _dot(
                              label: ReaderTheme.displayName(preset.name),
                              color: preset.background,
                              selected: _state.theme == preset.name,
                              borderColor: readerTheme.divider,
                              onTap: () =>
                                  commit(() => _state.theme = preset.name),
                            ),
                          // 自定义颜色
                          _dot(
                            label: '自定义',
                            color: _state.theme.startsWith('custom_')
                                ? _state.currentTheme.background
                                : Colors.grey.shade300,
                            selected: _state.theme.startsWith('custom_'),
                            borderColor: readerTheme.divider,
                            isCustom: true,
                            onTap: () async {
                              final color = await _showColorPicker(
                                _state.currentTheme.background,
                              );
                              if (color != null) {
                                final theme = ReaderTheme.custom(color);
                                commit(() => _state.theme = theme.name);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 更多设置 —— 对齐轻阅时光：整页（返回圆钮 + 居中标题 + 分组白卡）。
  ///
  /// 开关改动立即生效：显示类开关（顶栏/底栏/进度/段评）需要重排分页，
  /// 其余只写存储。备份/恢复/更改类型复用 ⋮ 菜单里的同一套实现。
  void _showMoreSettingsPage() {
    _hideController();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) {
          return StatefulBuilder(
            builder: (pageContext, pageSetState) {
              void commit(VoidCallback fn, {bool rebuildPages = false}) {
                setState(fn);
                pageSetState(() {});
                _saveSettings();
                if (rebuildPages) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      _rebuildPages(context.read<ReaderProvider>());
                    }
                  });
                }
              }

              Widget switchRow(
                String label,
                bool value,
                ValueChanged<bool> onChanged, {
                bool enabled = true,
                String? subtitle,
              }) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label,
                                style: TextStyle(
                                    fontSize: 15,
                                    color: enabled
                                        ? const Color(0xFF222222)
                                        : const Color(0xFFAAAAAA))),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(subtitle,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF999999))),
                              ),
                          ],
                        ),
                      ),
                      Switch(
                          value: value,
                          onChanged: enabled ? onChanged : null),
                    ],
                  ),
                );
              }

              /// 「多选一」行：右侧显示当前值，点了弹底部选项单。
              Widget choiceRow(
                String label,
                String valueLabel,
                VoidCallback onTap,
              ) {
                return InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(label,
                              style: const TextStyle(
                                  fontSize: 15, color: Color(0xFF222222))),
                        ),
                        Text(valueLabel,
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF888888))),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right,
                            size: 20, color: Color(0xFFAAAAAA)),
                      ],
                    ),
                  ),
                );
              }

              /// 底部选项单：标题 + 一排带 ✓ 的选项。
              void pickOption({
                required String title,
                required List<String> options,
                required int current,
                required ValueChanged<int> onSelected,
              }) {
                showModalBottomSheet<void>(
                  context: pageContext,
                  backgroundColor: Colors.white,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  builder: (sheetCtx) {
                    return SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Text(title,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF222222))),
                          ),
                          for (var i = 0; i < options.length; i++)
                            ListTile(
                              title: Text(options[i],
                                  style: const TextStyle(fontSize: 15)),
                              trailing: i == current
                                  ? const Icon(Icons.check,
                                      color: Color(0xFF7CB7B2))
                                  : null,
                              onTap: () {
                                Navigator.pop(sheetCtx);
                                onSelected(i);
                              },
                            ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    );
                  },
                );
              }

              Widget card(String title, List<Widget> children) {
                return Container(
                  margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF222222),
                          ),
                        ),
                      ),
                      ...children,
                      const SizedBox(height: 8),
                    ],
                  ),
                );
              }

              return Scaffold(
                backgroundColor: const Color(0xFFF5F6F8),
                body: SafeArea(
                  child: Column(
                    children: [
                      // ---- 标题栏：返回圆钮 + 居中标题 ----
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Material(
                                color: Colors.white,
                                shape: const CircleBorder(),
                                elevation: 1,
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => Navigator.pop(pageContext),
                                  child: const SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: Icon(Icons.arrow_back_ios_new,
                                        size: 18, color: Color(0xFF333333)),
                                  ),
                                ),
                              ),
                            ),
                            const Text(
                              '更多设置',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF222222),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            card('显示设置', [
                              switchRow(
                                '顶部区域（章节名）',
                                _state.showTopBar,
                                (v) => commit(() => _state.showTopBar = v,
                                    rebuildPages: true),
                              ),
                              switchRow(
                                '底部区域（时间/电量/页码）',
                                _state.showBottomBar,
                                (v) => commit(() => _state.showBottomBar = v,
                                    rebuildPages: true),
                              ),
                              switchRow(
                                '隐藏状态栏',
                                _state.hideStatusBar,
                                (v) => commit(() {
                                  _state.hideStatusBar = v;
                                  unawaited(
                                      SystemUiService.setStatusBarHidden(v));
                                }),
                              ),
                              switchRow(
                                '隐藏标题',
                                _state.hideTitle,
                                (v) => commit(() => _state.hideTitle = v,
                                    rebuildPages: true),
                              ),
                              choiceRow(
                                '标题对齐',
                                const ['左对齐', '居中', '右对齐']
                                    [_state.titleAlign.clamp(0, 2)],
                                () => pickOption(
                                  title: '标题对齐',
                                  options: const ['左对齐', '居中', '右对齐'],
                                  current: _state.titleAlign.clamp(0, 2),
                                  onSelected: (i) => commit(
                                      () => _state.titleAlign = i),
                                ),
                              ),
                              switchRow(
                                '页眉页脚分割线',
                                _state.showHeaderFooterDivider,
                                (v) => commit(
                                    () => _state.showHeaderFooterDivider = v,
                                    rebuildPages: true),
                              ),
                              choiceRow(
                                '显示进度',
                                const ['关闭', '本章', '全书', '本章+全书']
                                    [_state.progressMode.clamp(0, 3)],
                                () => pickOption(
                                  title: '显示进度',
                                  options: const ['关闭', '本章', '全书', '本章+全书'],
                                  current: _state.progressMode.clamp(0, 3),
                                  onSelected: (i) => commit(
                                      () => _state.progressMode = i),
                                ),
                              ),
                              switchRow(
                                '显示时间',
                                _state.showFooterTime,
                                (v) =>
                                    commit(() => _state.showFooterTime = v),
                              ),
                              switchRow(
                                '显示电量',
                                _state.showFooterBattery,
                                (v) =>
                                    commit(() => _state.showFooterBattery = v),
                              ),
                              switchRow(
                                '显示段评',
                                _state.showParagraphComment,
                                (v) => commit(
                                    () => _state.showParagraphComment = v,
                                    rebuildPages: true),
                              ),
                            ]),
                            card('翻页设置', [
                              // iOS 没有公开的音量键事件 API（原生侧直接回 false），
                              // 这行在 iPhone 上置灰并说明原因。
                              switchRow(
                                '音量键翻页',
                                _state.volumeKeyFlip,
                                (v) => commit(() {
                                  _state.volumeKeyFlip = v;
                                  unawaited(
                                      SystemUiService.setVolumeKeyActive(v));
                                }),
                                enabled: defaultTargetPlatform !=
                                    TargetPlatform.iOS,
                                subtitle: defaultTargetPlatform ==
                                        TargetPlatform.iOS
                                    ? 'iOS 系统不开放音量键，无法翻页'
                                    : null,
                              ),
                              switchRow(
                                '上滑退出',
                                _state.swipeUpExit,
                                (v) => commit(() => _state.swipeUpExit = v),
                              ),
                              switchRow(
                                '下滑书签',
                                _state.swipeDownBookmark,
                                (v) =>
                                    commit(() => _state.swipeDownBookmark = v),
                              ),
                              switchRow(
                                '底部对齐',
                                _state.bottomAlignLastPage,
                                (v) => commit(
                                    () => _state.bottomAlignLastPage = v),
                              ),
                              choiceRow(
                                '菜单滑动条',
                                _state.sliderByPage ? '按分页' : '按章节',
                                () => pickOption(
                                  title: '菜单滑动条',
                                  options: const ['按章节', '按分页'],
                                  current: _state.sliderByPage ? 1 : 0,
                                  onSelected: (i) => commit(
                                      () => _state.sliderByPage = i == 1),
                                ),
                              ),
                              switchRow(
                                '自动下一章',
                                _state.autoNext,
                                (v) => commit(() => _state.autoNext = v),
                              ),
                              if (!_state.isComic)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  child: Row(
                                    children: [
                                      const Text('翻页间隔',
                                          style: TextStyle(
                                              fontSize: 15,
                                              color: Color(0xFF222222))),
                                      Expanded(
                                        child: Slider(
                                          value: _state.autoPageInterval,
                                          min: 3,
                                          max: 60,
                                          divisions: 57,
                                          label:
                                              '${_state.autoPageInterval.toStringAsFixed(0)}秒',
                                          onChanged: (v) => commit(() =>
                                              _state.autoPageInterval = v),
                                        ),
                                      ),
                                      Text(
                                        '${_state.autoPageInterval.toStringAsFixed(0)}秒',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: Color(0xFF888888)),
                                      ),
                                    ],
                                  ),
                                ),
                            ]),
                            card('其他', [
                              choiceRow(
                                '屏幕常亮',
                                switch (_state.wakelockMinutes) {
                                  0 => '关闭',
                                  5 => '5 分钟',
                                  10 => '10 分钟',
                                  _ => '常亮',
                                },
                                () => pickOption(
                                  title: '屏幕常亮',
                                  options: const ['关闭', '5 分钟', '10 分钟', '常亮'],
                                  current: switch (_state.wakelockMinutes) {
                                    0 => 0,
                                    5 => 1,
                                    10 => 2,
                                    _ => 3,
                                  },
                                  onSelected: (i) => commit(() {
                                    _state.wakelockMinutes =
                                        const [0, 5, 10, -1][i];
                                    _applyWakelock();
                                  }),
                                ),
                              ),
                              switchRow(
                                '锁定屏幕（竖屏）',
                                _state.lockOrientation,
                                (v) => commit(() {
                                  _state.lockOrientation = v;
                                  unawaited(
                                      SystemChrome.setPreferredOrientations(
                                          v
                                              ? const [
                                                  DeviceOrientation.portraitUp
                                                ]
                                              : const []));
                                }),
                              ),
                              switchRow(
                                '目录倒序',
                                _state.tocReversed,
                                (v) => commit(() => _state.tocReversed = v),
                              ),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 面板底部的圆点（背景色选择）
  ///
  /// 选中时在圆点外面套一圈橙色描边——注意必须画在圆点**外面**，
  /// 直接给圆点加 border 会糊在一起，和参考图对不上。
  Widget _dot({
    required String label,
    required Color color,
    required bool selected,
    required Color borderColor,
    required VoidCallback onTap,
    bool isCustom = false,
  }) {
    final dot = _ThemeColorDot(
      label: label,
      color: color,
      selected: selected,
      onTap: onTap,
      isCustom: isCustom,
      borderColor: borderColor,
    );
    return selected ? _ThemeColorDotRing(child: dot) : dot;
  }

  /// 面板底部的宽按钮（间距设置 / 翻页设置）
  Widget _panelButton({
    required IconData icon,
    required String label,
    required Color textColor,
    required Color borderColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: textColor),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(fontSize: 15, color: textColor),
            ),
          ],
        ),
      ),
    );
  }

  /// 间距设置抽屉
  void _showSpacingSettingsSheet(ReaderProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _state.currentTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            void commit(VoidCallback fn, {bool rebuildPages = false}) {
              setState(fn);
              sheetSetState(() {});
              _saveSettings();
              if (rebuildPages) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _rebuildPages(context.read<ReaderProvider>());
                });
              }
            }

            return SafeArea(
              top: false,
              // 【为什么要能滚】showModalBottomSheet 默认把高度卡在屏幕的
              // 9/16。这个面板本来就快顶到上限了，加上「最大宽度」一行 + 一条
              // 滑动条之后必然超 —— 不套滚动的话，矮屏（手机横屏、浏览器窗口
              // 拉矮）上会直接报 RenderFlex overflow，最后一项被切掉。
              // 套上之后超出的部分滚动即可，其他面板也是这么做的。
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const Text('间距设置',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 16),

                      // ---- 行距 ----
                      _SettingRow(
                        label: '行距',
                        value: _state.lineHeight.toStringAsFixed(1),
                        child: Slider(
                          value: _state.lineHeight,
                          min: 1.2,
                          max: 2.6,
                          divisions: 14,
                          label: _state.lineHeight.toStringAsFixed(1),
                          onChanged: (v) => commit(() => _state.lineHeight = v,
                              rebuildPages: true),
                        ),
                      ),

                      // ---- 段间距 ----
                      _SettingRow(
                        label: '段间距',
                        value: _state.paragraphSpacing.round().toString(),
                        child: Slider(
                          value: _state.paragraphSpacing,
                          min: 4,
                          max: 24,
                          // 步长 1px：默认值 7 必须正好落在刻度上，
                          // 否则滑块一拖就会跳到邻近的偶数上
                          divisions: 20,
                          label: _state.paragraphSpacing.round().toString(),
                          onChanged: (v) => commit(
                              () => _state.paragraphSpacing = v,
                              rebuildPages: true),
                        ),
                      ),

                      // ---- 首行空格 ----
                      _SettingRow(
                        label: '首行空格',
                        value: _state.firstLineIndent.round().toString(),
                        child: Slider(
                          value: _state.firstLineIndent,
                          min: 0,
                          max: 4,
                          divisions: 4,
                          label: _state.firstLineIndent.round().toString(),
                          onChanged: (v) => commit(
                              () => _state.firstLineIndent = v,
                              rebuildPages: true),
                        ),
                      ),

                      // ---- 左右边距 ----
                      _SettingRow(
                        label: '左右边距',
                        value: _state.horizontalPadding.round().toString(),
                        child: Slider(
                          value: _state.horizontalPadding,
                          min: 8,
                          max: 48,
                          divisions: 10,
                          label: _state.horizontalPadding.round().toString(),
                          onChanged: (v) => commit(
                              () => _state.horizontalPadding = v,
                              rebuildPages: true),
                        ),
                      ),

                      // ---- 上方边距 ----
                      _SettingRow(
                        label: '上方边距',
                        value: _state.topPadding.round().toString(),
                        child: Slider(
                          value: _state.topPadding,
                          min: 0,
                          max: 48,
                          // 步长 2px：默认值 10 要正好落在刻度上
                          divisions: 24,
                          label: _state.topPadding.round().toString(),
                          onChanged: (v) => commit(() => _state.topPadding = v,
                              rebuildPages: true),
                        ),
                      ),

                      // ---- 最大宽度 ----
                      // 官方这一项的形状是「最大宽度  [600]  [开关]」+ 下面一条
                      // 占满整行的滑动条（前四项的滑动条是跟在标签后面的，这一项
                      // 不是 —— 因为它的开关占掉了标签右侧的位置）。
                      //
                      // 【为什么要有开关】限宽只在宽屏上才有意义：手机上屏宽本来
                      // 就小于 600，开不开都一样。给个总开关，想铺满整屏时可以
                      // 彻底关掉，不用把滑动条拖到最大值去凑。
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 52,
                              child: Text('最大宽度',
                                  style: TextStyle(fontSize: 15)),
                            ),
                            const Spacer(),
                            Text(
                              '${AppSettings.instance.readerMaxWidth}',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Switch(
                              value: AppSettings.instance.readerMaxWidthEnabled,
                              onChanged: (v) => commit(
                                  () => AppSettings.instance
                                      .setReaderMaxWidthEnabled(v),
                                  rebuildPages: true),
                            ),
                          ],
                        ),
                      ),
                      Slider(
                        value: AppSettings.instance.readerMaxWidth
                            .toDouble()
                            .clamp(
                              AppSettings.readerMaxWidthMin.toDouble(),
                              AppSettings.readerMaxWidthMax.toDouble(),
                            ),
                        min: AppSettings.readerMaxWidthMin.toDouble(),
                        max: AppSettings.readerMaxWidthMax.toDouble(),
                        divisions: (AppSettings.readerMaxWidthMax -
                                AppSettings.readerMaxWidthMin) ~/
                            50,
                        label: '${AppSettings.instance.readerMaxWidth}',
                        // 关掉开关时把滑动条置灰（onChanged 传 null），但**保留
                        // 当前数值** —— 再打开时还是原来那个宽度，不用重新拖一遍。
                        // 这里显式写出 `double v`：三元表达式一边是闭包一边是
                        // null，靠上下文推断虽然也行，但写清楚更稳。
                        onChanged: AppSettings.instance.readerMaxWidthEnabled
                            ? (double v) => commit(
                                  () => AppSettings.instance
                                      .setReaderMaxWidth(v.round()),
                                  rebuildPages: true,
                                )
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }


  /// 「听书设置」面板 —— 对齐 3.41：
  /// 三个开关（允许听书翻页 / 显示章节切换 / 延迟翻页）+ 一个「朗读引擎」入口卡片。
  ///
  /// 原来这里是「语速滑杆 + 语音下拉框」，而语速在朗读控制栏上已经有了，
  /// 下拉框又长得跟正文界面完全不是一个体系。
  void _showTtsSettingsSheet() {
    final readerTheme = _state.currentTheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: readerTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            void commit(VoidCallback fn) {
              setState(fn);
              sheetSetState(() {});
              unawaited(_saveSettings());
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text('听书设置',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w600)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    _ttsSwitchTile(
                      title: '允许听书翻页',
                      value: _state.ttsAllowPageTurn,
                      onChanged: (v) =>
                          commit(() => _state.ttsAllowPageTurn = v),
                    ),
                    _ttsSwitchTile(
                      title: '显示章节切换',
                      value: _state.ttsShowChapterSwitch,
                      onChanged: (v) =>
                          commit(() => _state.ttsShowChapterSwitch = v),
                    ),
                    _ttsSwitchTile(
                      title: '延迟翻页',
                      value: _state.ttsDelayPageTurn,
                      onChanged: (v) =>
                          commit(() => _state.ttsDelayPageTurn = v),
                    ),
                    const SizedBox(height: 12),
                    // 朗读引擎入口（3.41 是一个灰底卡片，右边一个 ›）
                    InkWell(
                      onTap: () => _showTtsEngineSheet(
                        onPicked: () => sheetSetState(() {}),
                      ),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: readerTheme.text.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '朗读引擎',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: readerTheme.secondaryText),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(Icons.cloud_outlined,
                                          size: 16, color: readerTheme.text),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          _currentVoiceLabel(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 14,
                                              color: readerTheme.text),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right,
                                size: 20, color: readerTheme.secondaryText),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 「听书设置」里的一行开关：标题 + 说明图标 + 右侧 Switch
  Widget _ttsSwitchTile({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = _state.currentTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(title,
                      style: TextStyle(fontSize: 15, color: theme.text)),
                ),
                const SizedBox(width: 6),
                Icon(Icons.help_outline, size: 15, color: theme.secondaryText),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// 当前选中的朗读引擎名（没选 HTTP 引擎就显示系统语音）
  String _currentVoiceLabel() {
    final http = _tts.httpEngine;
    if (http != null) return http.name;
    final id = _tts.selectedVoiceId;
    if (id == null || id.trim().isEmpty) return '系统语音';
    return id;
  }

  /// 朗读引擎选择面板 —— 对齐 3.41：搜索框 + 一整列可选项。
  ///
  /// 【为什么要把「我的 → 朗读引擎」里的引擎列在最上面】
  /// 上一版只列了设备上的系统语音，用户反馈「阅读引擎无法选择 —— 我的 ——
  /// 朗读引擎里面的引擎」。后端那套 HTTP TTS 引擎（`/getalltts`）现在已经
  /// 接进播放链路（见 TtsService：选中后由 `/tts` 合成音频、audioplayers 播放），
  /// 所以这里把它们列出来并能真正选中生效。
  void _showTtsEngineSheet({VoidCallback? onPicked}) {
    final readerTheme = _state.currentTheme;
    final voices = _tts.voices;
    final token = context.read<UserProvider>().token ?? '';
    var query = '';
    var loadingEngines = true;
    var enginesRequested = false;
    List<TtsEngine> engines = [];

    void loadEngines(StateSetter sheetSetState) {
      // 面板在加载完成前会被搜索框的每次输入重建，不加这道闸就会并发发一堆请求
      if (enginesRequested) return;
      enginesRequested = true;
      ApiService.instance.getAllTts(token).then((list) {
        if (!mounted) return;
        sheetSetState(() {
          engines = list;
          loadingEngines = false;
        });
      }).catchError((_) {
        if (!mounted) return;
        sheetSetState(() => loadingEngines = false);
      });
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: readerTheme.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, sheetSetState) {
            if (loadingEngines) loadEngines(sheetSetState);
            final q = query.trim().toLowerCase();
            final engineList = engines.where((e) {
              if (q.isEmpty) return true;
              return e.name.toLowerCase().contains(q) ||
                  e.url.toLowerCase().contains(q);
            }).toList(growable: false);
            final voiceList = voices.where((v) {
              if (q.isEmpty) return true;
              final name =
                  (v['name'] ?? v['identifier'] ?? '').toString().toLowerCase();
              final locale = (v['locale'] ?? '').toString().toLowerCase();
              return name.contains(q) || locale.contains(q);
            }).toList(growable: false);

            final selectedId = _tts.httpEngine?.id;

            return SafeArea(
              top: false,
              child: SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.72,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: TextField(
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '搜索引擎',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                          ),
                        ),
                        onChanged: (v) {
                          query = v;
                          sheetSetState(() {});
                        },
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          // ---- 「我的 → 朗读引擎」里配的 HTTP 引擎 ----
                          _ttsSectionHeader(readerTheme, '我的朗读引擎'),
                          _ttsEngineTile(
                            readerTheme: readerTheme,
                            icon: Icons.phone_android,
                            title: '系统语音（默认）',
                            selected: selectedId == null,
                            onTap: () async {
                              await _tts.setHttpEngine(null);
                              if (!mounted) return;
                              setState(() {});
                              Navigator.pop(sheetContext);
                              onPicked?.call();
                            },
                          ),
                          if (loadingEngines)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            )
                          else if (engineList.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                              child: Text(
                                '还没有配置朗读引擎（我的 → 朗读引擎）',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: readerTheme.secondaryText,
                                ),
                              ),
                            )
                          else
                            for (final e in engineList)
                              _ttsEngineTile(
                                readerTheme: readerTheme,
                                icon: Icons.cloud_outlined,
                                title: e.name,
                                selected: selectedId == e.id,
                                onTap: () async {
                                  await _tts.setHttpEngine(e);
                                  if (!mounted) return;
                                  setState(() {});
                                  Navigator.pop(sheetContext);
                                  onPicked?.call();
                                },
                              ),
                          // ---- 设备上的系统语音 ----
                          _ttsSectionHeader(readerTheme, '系统语音'),
                          if (voiceList.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                              child: Text(
                                '没有匹配的系统语音',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: readerTheme.secondaryText,
                                ),
                              ),
                            )
                          else
                            for (final v in voiceList)
                              Builder(builder: (_) {
                                final id =
                                    (v['name'] ?? v['identifier'] ?? '')
                                        .toString();
                                final locale =
                                    (v['locale'] ?? '').toString();
                                return _ttsEngineTile(
                                  readerTheme: readerTheme,
                                  icon: Icons.record_voice_over_outlined,
                                  title: locale.isEmpty
                                      ? id
                                      : '$id ($locale)',
                                  selected: selectedId == null &&
                                      id == _tts.selectedVoiceId,
                                  onTap: () async {
                                    await _tts.setHttpEngine(null);
                                    await _tts.setVoiceById(id);
                                    if (!mounted) return;
                                    setState(() {});
                                    Navigator.pop(sheetContext);
                                    onPicked?.call();
                                  },
                                );
                              }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _ttsSectionHeader(ReaderTheme readerTheme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: readerTheme.secondaryText,
        ),
      ),
    );
  }

  Widget _ttsEngineTile({
    required ReaderTheme readerTheme,
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    const accent = Color(0xFF009688);
    return ListTile(
      dense: true,
      leading: Icon(
        icon,
        size: 20,
        color: selected ? accent : readerTheme.secondaryText,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          color: selected ? accent : readerTheme.text,
        ),
      ),
      trailing: selected
          ? const Icon(Icons.check, size: 18, color: accent)
          : null,
      onTap: onTap,
    );
  }

  void _showTtsTimerSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('定时停止',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              for (final minutes in <int?>[null, 15, 30, 60])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(minutes == null ? '关闭定时' : '$minutes 分钟后停止'),
                  trailing: _state.ttsSleepMinutes == minutes
                      ? const Icon(Icons.check, color: Color(0xFF00A88F))
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setTtsSleepTimer(minutes);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _setTtsSleepTimer(int? minutes) {
    _ttsSleepTimer?.cancel();
    setState(() => _state.ttsSleepMinutes = minutes);
    if (minutes == null) return;
    _ttsSleepTimer = Timer(Duration(minutes: minutes), () async {
      await _stopTts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('朗读已按定时停止')),
      );
    });
  }

  /// ⋮ 更多菜单 —— 对齐轻阅时光：居中白色圆角卡片。
  ///
  /// 头部是「封面 + 书名 + 作者 + 详情胶囊」，下面 4×3 灰底宫格，
  /// 最底部一个「关闭」。
  void _showMorePanel(ReaderProvider provider) {
    final book = provider.book;
    if (book == null) return;
    _hideController();
    final inShelf = _isCurrentBookInShelf(provider);

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final tiles = <_MoreMenuItem>[
          _MoreMenuItem(
            icon: Icons.cloud_download_outlined,
            label: '批量下载',
            onTap: () {
              Navigator.pop(dialogContext);
              _showBatchDownloadSheet(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.login,
            label: '书源登录',
            onTap: () {
              Navigator.pop(dialogContext);
              _openSourceLogin(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.link,
            label: '正文地址',
            onTap: () {
              Navigator.pop(dialogContext);
              _copyChapterUrl(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.bookmark_border,
            label: '添加书签',
            onTap: () {
              Navigator.pop(dialogContext);
              _toggleBookmark(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.search,
            label: '搜索正文',
            onTap: () {
              Navigator.pop(dialogContext);
              _openBookSearch(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.close,
            label: '替换净化',
            onTap: () {
              Navigator.pop(dialogContext);
              Navigator.pushNamed(context, AppRoutes.replaceRules);
            },
          ),
          _MoreMenuItem(
            icon: Icons.format_clear,
            label: '起效净化',
            onTap: () {
              Navigator.pop(dialogContext);
              _applyReplaceRules();
            },
          ),
          // 轻阅时光这一格是「高亮规则」，Qread 没有高亮规则功能，
          // 这一格放「更改类型」。
          _MoreMenuItem(
            icon: Icons.category_outlined,
            label: '更改类型',
            onTap: () {
              Navigator.pop(dialogContext);
              _showChangeTypeDialog(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.open_in_browser,
            label: '用浏览器打开',
            onTap: () {
              Navigator.pop(dialogContext);
              _openChapterInBrowser(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.swap_horiz,
            label: '换源',
            onTap: () {
              Navigator.pop(dialogContext);
              _changeBookSource(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.refresh,
            label: '刷新',
            onTap: () {
              Navigator.pop(dialogContext);
              _refreshCurrentChapter(provider);
            },
          ),
          _MoreMenuItem(
            icon: Icons.info_outline,
            label: '显示日志',
            onTap: () {
              Navigator.pop(dialogContext);
              _showAppLog();
            },
          ),
        ];

        return Dialog(
          backgroundColor: Colors.white,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ---- 头部：封面 + 书名/作者 + 详情 ----
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BookCover(
                      url: book.customCoverUrl?.trim().isNotEmpty == true
                          ? book.customCoverUrl
                          : book.coverUrl,
                      sourceUrl: book.origin,
                      width: 58,
                      height: 78,
                      radius: 6,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.name ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF222222),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            book.author ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF888888),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _MoreHeaderPill(
                                label: '详情',
                                onTap: () {
                                  Navigator.pop(dialogContext);
                                  Navigator.pushNamed(
                                    context,
                                    AppRoutes.bookInfo,
                                    arguments: BookInfoPageArgs(
                                      book: book,
                                      fromBookshelf: inShelf,
                                    ),
                                  );
                                },
                              ),
                              if (!inShelf) ...[
                                const SizedBox(width: 8),
                                _MoreHeaderPill(
                                  label: '+ 书架',
                                  onTap: () {
                                    Navigator.pop(dialogContext);
                                    _addCurrentBookToShelf(provider);
                                  },
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                // ---- 4×3 宫格 ----
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.74,
                  children: tiles,
                ),
                const SizedBox(height: 6),
                // ---- 关闭 ----
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF222222),
                    minimumSize: const Size(120, 44),
                  ),
                  child: const Text('关闭', style: TextStyle(fontSize: 16)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 批量下载 —— 对齐轻阅时光的「选择下载章节」弹窗：
  /// 后20章 / 后50章 / 后100章 / 后面全部章节 + 自定义后多少章。
  ///
  /// 下载走的是 [ReaderProvider.cacheChapterRange]：逐章写进本地磁盘缓存，
  /// 已在缓存里的章节会跳过，所以重复下载同一区间不会浪费流量。
  /// 批量下载（轻阅时光样式）—— 弹窗与进度条在
  /// [showBatchDownloadDialog] 里，详情页「缓存书籍」也用它。
  void _showBatchDownloadSheet(ReaderProvider provider) {
    final token = _token;
    if (token == null || token.isEmpty) {
      _toast('请先登录');
      return;
    }
    showBatchDownloadDialog(
      context,
      totalChapters: provider.chapters.length,
      currentChapterIndex:
          _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
      runner: (start, count, {required onProgress, required isCancelled}) =>
          provider.cacheChapterRange(
        token,
        start,
        count,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
      onToast: _toast,
    );
  }

  /// 书源登录：取书源详情，按 loginUi / loginUrl 走 JS 登录或 WebView 登录，
  /// 回来后把 cookie 同步给服务端。
  Future<void> _openSourceLogin(ReaderProvider provider) async {
    final book = provider.book;
    final token = _token;
    if (book == null) return;
    if (token == null || token.isEmpty) {
      _toast('请先登录');
      return;
    }
    final sourceUrl = book.origin ?? '';
    if (sourceUrl.isEmpty) {
      _toast('当前书没有书源');
      return;
    }
    final detail = await context
        .read<SourceManageProvider>()
        .getSourceDetail(token, sourceUrl);
    if (!mounted) return;
    final jsonStr = detail?['data']?['json']?.toString() ?? '';
    Map<String, dynamic> json = {};
    if (jsonStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) json = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    String? strOf(String key) {
      final v = json[key]?.toString().trim() ?? '';
      return v.isEmpty ? null : v;
    }

    final loginUi = strOf('loginUi');
    final loginUrl = strOf('loginUrl');
    final sourceName = book.originName ?? '书源';

    if (loginUi != null) {
      await Navigator.pushNamed(
        context,
        AppRoutes.sourceLogin,
        arguments: SourceLoginPageArgs(
          sourceUrl: sourceUrl,
          sourceName: sourceName,
          type: 'bookSource',
          loginUi: loginUi,
          loginUrl: loginUrl,
          variableComment: strOf('variableComment'),
          header: strOf('header'),
        ),
      );
    } else if (loginUrl != null) {
      await Navigator.pushNamed(
        context,
        AppRoutes.sourceWebLogin,
        arguments: WebViewLoginPageArgs(
          sourceUrl: sourceUrl,
          sourceName: sourceName,
          type: 'bookSource',
          loginUrl: loginUrl,
          headers: SourceLoginPageArgs(
            sourceUrl: sourceUrl,
            sourceName: sourceName,
            type: 'bookSource',
            header: strOf('header'),
          ).headerMap,
        ),
      );
    } else {
      _toast('该书源没有登录入口');
      return;
    }
    if (!mounted) return;
    // 登录回来后再同步一次（JS 登录那条路 cookie 在服务端，客户端不知情）。
    unawaited(CookieSyncService.instance.syncOne(token, sourceUrl));
  }

  /// 当前章节的原始地址：优先章节的 resourceUrl，退到 tag，再退到书籍地址。
  String _chapterRawUrl(ReaderProvider provider) {
    final chapter = _displayedChapter(provider);
    final resource = chapter?.resourceUrl?.trim() ?? '';
    if (resource.isNotEmpty) return resource;
    final tag = chapter?.tag?.trim() ?? '';
    if (tag.isNotEmpty) return tag;
    return provider.book?.bookUrl ?? '';
  }

  /// 正文地址：把当前章节的原始地址复制到剪贴板。
  void _copyChapterUrl(ReaderProvider provider) {
    final url = _chapterRawUrl(provider);
    if (url.isEmpty) {
      _toast('没有可复制的地址');
      return;
    }
    Clipboard.setData(ClipboardData(text: url));
    _toast('正文地址已复制');
  }

  /// 用浏览器打开当前章节的原始地址。
  Future<void> _openChapterInBrowser(ReaderProvider provider) async {
    final url = _chapterRawUrl(provider);
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      _toast('当前章节没有可在浏览器打开的地址');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _toast('打不开浏览器');
  }

  /// 书内全文搜索（不带关键词进入，直接在搜索页里输入）。
  void _openBookSearch(ReaderProvider provider) {
    final book = provider.book;
    if (book == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookTextSearchPage(
          book: book,
          accessToken: _token ?? '',
          chapters: provider.chapters,
          keyword: '',
          loadChapterText: (index) =>
              provider.peekChapterContent(_token ?? '', index),
          onJumpToResult: _jumpToSearchResult,
        ),
      ),
    );
  }

  /// 刷新当前章节：跳过内存/磁盘缓存直接回源，拿到后覆盖写盘再重排。
  ///
  /// 【为什么不能只 `_openChapter`】`_openChapter` 会优先吃预排版缓存
  /// （`prefetchedNext/PrevLayout`），而那份是**旧正文**排出来的 ——
  /// 必须先 `_invalidateLayoutCaches()` 把预排版作废，否则刷新完正文没变。
  Future<void> _refreshCurrentChapter(ReaderProvider provider) async {
    final token = _token;
    if (token == null) return;
    final current =
        _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0);
    try {
      await provider.forceReloadChapter(token, current);
    } catch (e) {
      if (!mounted) return;
      _toast('刷新失败：$e');
      return;
    }
    if (!mounted) return;
    _invalidateLayoutCaches();
    setState(() {});
    await _openChapter(current, chapterPosition: _state.chapterPosition);
    if (!mounted) return;
    _toast('已刷新当前章节');
  }

  /// 换源：跳到换源页，成功后重载当前章节
  Future<void> _changeBookSource(ReaderProvider provider) async {
    final book = provider.book;
    if (book == null) return;
    AppLog.add('打开换源：${book.name}（当前来源 ${book.originName ?? book.origin}）');
    final changed = await Navigator.pushNamed(
      context,
      AppRoutes.bookSourceSwitch,
      arguments: BookSourceSwitchArgs(book: book),
    );
    if (changed != true || !mounted) return;
    AppLog.add('换源成功 → ${book.originName ?? book.origin}');
    // 换源后章节列表 / 正文全变了：重设书籍、重拉章节、允许重新定位初始章节
    provider.setBook(book);
    _bookUrl = book.bookUrl;
    _state.initialChapterOpened = false;
    final token = _token;
    if (token != null) {
      await provider.loadChapters(token, loadInitialContent: false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已换源到「${book.originName ?? book.origin}」'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 显示运行日志（段评打不开 / 换源失败等都会记在这里）
  void _showAppLog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('运行日志'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: AppLog.isEmpty
              ? const Center(child: Text('暂无日志'))
              : ListView.builder(
                  itemCount: AppLog.entries.length,
                  itemBuilder: (_, i) {
                    final lines = AppLog.entries.reversed.toList();
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        lines[i],
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              AppLog.clear();
              Navigator.pop(ctx);
            },
            child: const Text('清空'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 当前书是否已在书架（决定 ⋮ 菜单头部要不要显示「+ 书架」）。
  ///
  /// 【为什么用 read 不用 watch】这个方法现在是从对话框 builder / 点击回调里
  /// 调的一次性读取，不是在 build 里订阅 —— watch 在非 build 时机调用会直接抛。
  bool _isCurrentBookInShelf(ReaderProvider provider) {
    final url = provider.book?.bookUrl;
    if (url == null || url.isEmpty) return true;
    final books = context.read<BookshelfProvider>().books;
    return books.any((b) => b.bookUrl == url);
  }

  /// 把当前正在读的书加入书架（对齐 3.41 中间胶囊的加号）
  Future<void> _addCurrentBookToShelf(ReaderProvider provider) async {
    final book = provider.book;
    final token = _token;
    if (book == null || token == null || token.isEmpty) {
      _toast('请先登录');
      return;
    }
    try {
      await ApiService.instance.saveBook(token, book);
      if (!mounted) return;
      await context
          .read<BookshelfProvider>()
          .loadBookshelf(token, refresh: true);
      _toast('已加入书架');
    } catch (e) {
      _toast('加入失败：$e');
    }
  }

  void _showChangeTypeDialog(ReaderProvider provider) {
    final currentType = provider.book?.type ?? 0;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更改书籍类型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [0, 1, 2, 3].map((type) {
            final labels = ['小说', '听书', '漫画', '文件'];
            final icons = [
              Icons.menu_book,
              Icons.headphones,
              Icons.image,
              Icons.insert_drive_file,
            ];
            return ListTile(
              leading: Icon(
                type == currentType
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: type == currentType ? const Color(0xFF00A88F) : null,
              ),
              title: Row(
                children: [
                  Icon(icons[type], size: 20),
                  const SizedBox(width: 8),
                  Text(labels[type]),
                ],
              ),
              onTap: () {
                Navigator.pop(ctx);
                if (type != currentType) _changeBookType(provider, type);
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeBookType(ReaderProvider provider, int type) async {
    if (_token == null || _bookUrl == null) return;
    try {
      await ApiService.instance.changeBookType(_token!, _bookUrl!, type);
      if (!mounted) return;
      setState(() => _state.isComic = type == 2);
      provider.book?.type = type;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书籍类型已更新，请重新进入章节')),
      );
      _rebuildPages(provider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更改类型失败: $e')),
      );
    }
  }

  Future<void> _applyReplaceRules() async {
    final token = _token;
    final bookUrl = _bookUrl;
    if (token == null || bookUrl == null) return;
    final provider = context.read<ReaderProvider>();
    try {
      await ApiService.instance.updateUseReplaceRule(
        token,
        url: bookUrl,
        useReplaceRule: 1,
      );
      provider.book?.useReplaceRule = true;
      // 【不能只 _openChapter】
      // `_prefetchCache` 只按 chapterIndex 存，**不带净化开关**；缓存目录虽然分了
      // `replace_on` / `replace_off`，但内存里的 `_prefetchCache` 会先命中。
      // 所以刚把开关从关打到开时，如果只重开当前章，正文读到的还是关着时的旧内容
      // —— 表现就是「点了应用净化，正文一点没变」。
      // `_onReplaceRuleChanged` 会把内存缓存 + 磁盘缓存 + 预排版缓存一起作废。
      await _onReplaceRuleChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已应用净化规则并刷新当前章节')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('应用净化规则失败: $e')),
      );
    }
  }

  void _retry() {
    if (_token != null) {
      final provider = context.read<ReaderProvider>();
      if (provider.chapters.isEmpty) {
        provider.loadChapters(_token!, loadInitialContent: false);
      } else {
        _openChapter(
            _state.displayedChapterIndex(provider.book?.durChapterIndex ?? 0),
            chapterPosition: _state.chapterPosition);
      }
    }
  }

  /// 把「更多设置」里的系统类开关一次性应用到原生侧。
  /// 设置载入完成时、以及相关开关被改动后调用。
  void _applySystemUiSettings() {
    unawaited(SystemUiService.setStatusBarHidden(_state.hideStatusBar));
    unawaited(SystemUiService.setVolumeKeyActive(_state.volumeKeyFlip));
    if (_state.lockOrientation) {
      // 锁定竖屏（SystemChrome 是 Flutter 内置能力，不用动原生）
      unawaited(SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]));
    } else {
      unawaited(SystemChrome.setPreferredOrientations(const []));
    }
    _applyWakelock();
  }

  /// 「屏幕常亮」四档：0 关 / -1 常亮 / 5 / 10（分钟）。
  ///
  /// 档位模式（5/10）是「N 分钟无翻页后自动放屏」：先开常亮并起一个
  /// 倒计时，[_moveToPage] / 音量键等翻页动作会调 [_refreshWakelockTimer]
  /// 重置计时。到点放屏后设置值不变 —— 下一次翻页又会重新点亮并开始计时，
  /// 这正是轻阅时光档位档的行为。
  void _applyWakelock() {
    _wakelockTimer?.cancel();
    final minutes = _state.wakelockMinutes;
    if (minutes == 0) {
      unawaited(SystemUiService.setKeepScreenOn(false));
      return;
    }
    unawaited(SystemUiService.setKeepScreenOn(true));
    if (minutes > 0) {
      _wakelockTimer = Timer(Duration(minutes: minutes), () {
        unawaited(SystemUiService.setKeepScreenOn(false));
      });
    }
  }

  /// 翻页/点击时刷新档位倒计时（0 关 / -1 常亮时没有计时可刷）。
  void _refreshWakelockTimer() {
    if (_state.wakelockMinutes > 0) _applyWakelock();
  }

  /// 显示颜色选择器
  Future<Color?> _showColorPicker(Color initialColor) async {
    Color selected = initialColor;
    return showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择背景颜色'),
        content: SingleChildScrollView(
          child: _ColorPickerWidget(
            initialColor: initialColor,
            onColorChanged: (color) => selected = color,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, selected),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ⋮ 菜单辅助组件
// ============================================================

/// ⋮ 菜单宫格里的一格：灰底圆角方块 + 图标 + 下方标签。
class _MoreMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MoreMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFFF2F3F5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 24, color: const Color(0xFF333333)),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
          ),
        ],
      ),
    );
  }
}

/// ⋮ 菜单头部的灰色胶囊按钮（详情 / + 书架）。
class _MoreHeaderPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _MoreHeaderPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F3F5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
        ),
      ),
    );
  }
}

// ============================================================
// 设置面板辅助组件
// ============================================================

/// 设置行：左侧标签 + 右侧控件
class _SettingRow extends StatelessWidget {
  final String label;
  final String? value;
  final Widget child;

  const _SettingRow({
    required this.label,
    this.value,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: const TextStyle(fontSize: 15)),
          ),
          Expanded(child: child),
          if (value != null)
            SizedBox(
              width: 48,
              child: Text(
                value!,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 主题颜色圆点选择器
///
/// 参考图里只有圆点、没有文字标签；选中时在圆点外面套一圈橙色描边。
class _ThemeColorDot extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final bool isCustom;

  /// 描边色（未选中时圆点自身的外圈）
  final Color borderColor;

  const _ThemeColorDot({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.isCustom = false,
    this.borderColor = const Color(0xFFC1D5C1),
  });

  static const double _dotSize = 21;
  static const double _ringSize = 29;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: label,
        child: SizedBox(
          width: _ringSize,
          height: _ringSize,
          child: Center(
            child: Container(
              width: _dotSize,
              height: _dotSize,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: 1),
              ),
              child: isCustom
                  ? const Icon(Icons.add, color: Colors.grey, size: 14)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆点外面那圈「已选中」的橙色描边。
///
/// 单独抽出来是因为它必须画在圆点**外面**（中间留一点空隙），
/// 而圆点自身的 border 画在里面，两者叠加会糊成一团。
class _ThemeColorDotRing extends StatelessWidget {
  final Widget child;

  const _ThemeColorDotRing({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFFF9800), width: 2),
      ),
      child: child,
    );
  }
}

/// 简易颜色选择器 Widget
class _ColorPickerWidget extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;

  const _ColorPickerWidget({
    required this.initialColor,
    required this.onColorChanged,
  });

  @override
  State<_ColorPickerWidget> createState() => _ColorPickerWidgetState();
}

class _ColorPickerWidgetState extends State<_ColorPickerWidget> {
  late double _hue;
  late double _saturation;
  late double _lightness;

  @override
  void initState() {
    super.initState();
    final hsl = HSLColor.fromColor(widget.initialColor);
    _hue = hsl.hue;
    _saturation = hsl.saturation;
    _lightness = hsl.lightness;
  }

  Color get _currentColor =>
      HSLColor.fromAHSL(1.0, _hue, _saturation, _lightness).toColor();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 颜色预览
        Container(
          width: double.infinity,
          height: 48,
          decoration: BoxDecoration(
            color: _currentColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
        ),
        const SizedBox(height: 16),

        // 色相滑杆
        Row(
          children: [
            const SizedBox(width: 40, child: Text('色相')),
            Expanded(
              child: Slider(
                value: _hue,
                min: 0,
                max: 360,
                onChanged: (v) {
                  setState(() => _hue = v);
                  widget.onColorChanged(_currentColor);
                },
              ),
            ),
          ],
        ),

        // 饱和度滑杆
        Row(
          children: [
            const SizedBox(width: 40, child: Text('饱和')),
            Expanded(
              child: Slider(
                value: _saturation,
                min: 0,
                max: 1,
                onChanged: (v) {
                  setState(() => _saturation = v);
                  widget.onColorChanged(_currentColor);
                },
              ),
            ),
          ],
        ),

        // 明度滑杆
        Row(
          children: [
            const SizedBox(width: 40, child: Text('明度')),
            Expanded(
              child: Slider(
                value: _lightness,
                min: 0.05,
                max: 0.95,
                onChanged: (v) {
                  setState(() => _lightness = v);
                  widget.onColorChanged(_currentColor);
                },
              ),
            ),
          ],
        ),

        // 预设色块
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Colors.white,
            const Color(0xFFF7F1E6),
            const Color(0xFFF4E7CF),
            const Color(0xFFC2D8AA),
            const Color(0xFFC0EDC6),
            const Color(0xFFABCEE0),
            const Color(0xFFDBB8E2),
            const Color(0xFFD4B896),
            const Color(0xFF101417),
          ].map((c) {
            return GestureDetector(
              onTap: () {
                final hsl = HSLColor.fromColor(c);
                setState(() {
                  _hue = hsl.hue;
                  _saturation = hsl.saturation;
                  _lightness = hsl.lightness;
                });
                widget.onColorChanged(_currentColor);
              },
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.grey.shade400, width: 0.5),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
