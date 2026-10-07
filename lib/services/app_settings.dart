import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 书架排序方式
///
/// 对应官方 3.41「我的 → 阅读偏好 → 书架设置 → 书架排序」，
/// 默认「按阅读时间」——用户反馈「刚看完的书没排在最前面」就是因为
/// 之前根本没有排序（书架顺序 = 后端接口返回顺序）。
enum BookshelfSort {
  readTime('readTime', '按阅读时间'),
  updateTime('updateTime', '按更新时间'),
  name('name', '按书名'),
  author('author', '按作者'),
  manual('manual', '手动');

  const BookshelfSort(this.id, this.label);

  final String id;
  final String label;

  static BookshelfSort byId(String? id) {
    for (final v in BookshelfSort.values) {
      if (v.id == id) return v;
    }
    return BookshelfSort.readTime;
  }
}

/// 段评样式（对应 3.41「阅读设置 → 段评样式」）
enum CommentBubbleStyle {
  style1('style1', '样式1'),
  style2('style2', '样式2');

  const CommentBubbleStyle(this.id, this.label);

  final String id;
  final String label;

  static CommentBubbleStyle byId(String? id) {
    for (final v in CommentBubbleStyle.values) {
      if (v.id == id) return v;
    }
    return CommentBubbleStyle.style1;
  }
}

/// 夜间模式（对应 3.41「主题设置 → 夜间模式」）
enum NightMode {
  system('system', '跟随系统'),
  light('light', '关闭'),
  dark('dark', '开启');

  const NightMode(this.id, this.label);

  final String id;
  final String label;

  ThemeMode get themeMode => switch (this) {
        NightMode.system => ThemeMode.system,
        NightMode.light => ThemeMode.light,
        NightMode.dark => ThemeMode.dark,
      };

  static NightMode byId(String? id) {
    for (final v in NightMode.values) {
      if (v.id == id) return v;
    }
    return NightMode.system;
  }
}

/// 简繁转换方向
enum ChineseConvert {
  off('off', '不转换'),
  t2s('t2s', '繁体转简体'),
  s2t('s2t', '简体转繁体');

  const ChineseConvert(this.id, this.label);

  final String id;
  final String label;

  static ChineseConvert byId(String? id) {
    for (final v in ChineseConvert.values) {
      if (v.id == id) return v;
    }
    return ChineseConvert.off;
  }
}

/// 全局阅读偏好设置
///
/// 官方客户端把这一堆设置放在「我的 → 阅读偏好」里。本仓库以前把这些
/// 散在各处（阅读器内嵌弹窗 / 硬编码常量），这里统一收口：
/// 一个 [ChangeNotifier] + SharedPreferences 持久化，
/// 谁需要读就 `context.watch<AppSettings>()`。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  // ---- prefs key ----
  static const _kBookshelfSort = 'app_bookshelf_sort';
  static const _kNightMode = 'app_night_mode';
  static const _kChineseConvert = 'app_chinese_convert';
  static const _kTtsCacheCount = 'app_tts_cache_count';
  static const _kCommentStyle = 'app_comment_style';
  static const _kImageLimit = 'app_image_limit';
  static const _kUseReplaceRule = 'app_use_replace_rule';
  static const _kReplaceLocalStorage = 'app_replace_local_storage';
  static const _kTtsBackground = 'app_tts_background';
  static const _kSearchThreadCount = 'app_search_thread_count';
  static const _kWebSocketEnabled = 'app_websocket_enabled';
  static const _kShowSubscribe = 'app_show_subscribe';
  static const _kShowDiscover = 'app_show_discover';
  static const _kMultiScreen = 'app_multi_screen';
  static const _kDefaultCover = 'app_default_cover';

  /// 阅读正文的最大宽度（逻辑像素），以及它的启用开关。
  ///
  /// 官方网页版在「阅读界面 → 间距设置」面板最下面有这一项，形状是
  /// **「最大宽度 [600] [开关]」+ 一条滑动条**（默认开、默认 600）——
  /// 之所以带开关，是因为它只在宽屏上才有意义：手机上屏宽本来就小于 600，
  /// 限不限都一样，所以给个总开关让你能彻底关掉。
  ///
  /// 【为什么默认开】官方截图里开关是打开状态，且宽屏上一行太长确实很难读，
  /// 默认开是更好的开箱体验；窄屏上开了也等于没开，没有副作用。
  static const _kReaderMaxWidth = 'app_reader_max_width';
  static const _kReaderMaxWidthEnabled = 'app_reader_max_width_enabled';

  /// 「最大宽度」滑动条的取值范围与默认值（对齐官方网页版）
  static const int readerMaxWidthMin = 300;
  static const int readerMaxWidthMax = 1600;
  static const int readerMaxWidthDefault = 600;

  /// 翻页方式。**故意复用阅读器的 key**（`reader_page.dart` 里的
  /// `_keyPageAnimType`），这样在「阅读偏好 → 翻页设置」里改完，
  /// 下次进阅读器就能读到同一个值，不需要两边同步状态。
  static const _kPageAnimType = 'reader_page_anim_type';

  /// 翻页方式可选值（与 `reader_state.dart` 的 PageAnimType 一致）
  static const Map<String, String> pageAnimTypes = {
    'cover': '覆盖',
    'simulation': '仿真',
    'flipbook': '翻书',
    'slide': '左右',
    'scroll': '滚动',
    'none': '无',
  };

  // ---- 值 ----
  BookshelfSort _bookshelfSort = BookshelfSort.readTime;
  NightMode _nightMode = NightMode.system;
  ChineseConvert _chineseConvert = ChineseConvert.off;
  int _ttsCacheCount = 5;
  CommentBubbleStyle _commentStyle = CommentBubbleStyle.style1;
  int _imageLimit = 0;
  bool _useReplaceRule = true;
  bool _replaceLocalStorage = false;
  bool _ttsBackground = true;
  int _searchThreadCount = 4;
  bool _webSocketEnabled = false;
  bool _showSubscribe = true;
  bool _showDiscover = true;
  bool _multiScreen = false;
  bool _defaultCover = false;
  int _readerMaxWidth = readerMaxWidthDefault;
  bool _readerMaxWidthEnabled = true;
  String _pageAnimType = 'cover';

  // ---- getter ----
  BookshelfSort get bookshelfSort => _bookshelfSort;
  NightMode get nightMode => _nightMode;
  ChineseConvert get chineseConvert => _chineseConvert;
  int get ttsCacheCount => _ttsCacheCount;
  CommentBubbleStyle get commentStyle => _commentStyle;
  int get imageLimit => _imageLimit;
  bool get useReplaceRule => _useReplaceRule;
  bool get replaceLocalStorage => _replaceLocalStorage;
  bool get ttsBackground => _ttsBackground;
  int get searchThreadCount => _searchThreadCount;
  bool get webSocketEnabled => _webSocketEnabled;
  bool get showSubscribe => _showSubscribe;
  bool get showDiscover => _showDiscover;
  bool get multiScreen => _multiScreen;
  bool get defaultCover => _defaultCover;
  int get readerMaxWidth => _readerMaxWidth;
  bool get readerMaxWidthEnabled => _readerMaxWidthEnabled;
  String get pageAnimType => _pageAnimType;
  String get pageAnimTypeLabel => pageAnimTypes[_pageAnimType] ?? '覆盖';

  /// 是否需要在书架卡片上用「默认封面」（3.41 书架菜单里的「默认封面」）
  bool get useDefaultCover => _defaultCover;

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _bookshelfSort = BookshelfSort.byId(p.getString(_kBookshelfSort));
    _nightMode = NightMode.byId(p.getString(_kNightMode));
    _chineseConvert = ChineseConvert.byId(p.getString(_kChineseConvert));
    _ttsCacheCount = p.getInt(_kTtsCacheCount) ?? 5;
    _commentStyle = CommentBubbleStyle.byId(p.getString(_kCommentStyle));
    _imageLimit = p.getInt(_kImageLimit) ?? 0;
    _useReplaceRule = p.getBool(_kUseReplaceRule) ?? true;
    _replaceLocalStorage = p.getBool(_kReplaceLocalStorage) ?? false;
    _ttsBackground = p.getBool(_kTtsBackground) ?? true;
    _searchThreadCount = p.getInt(_kSearchThreadCount) ?? 4;
    _webSocketEnabled = p.getBool(_kWebSocketEnabled) ?? false;
    _showSubscribe = p.getBool(_kShowSubscribe) ?? true;
    _showDiscover = p.getBool(_kShowDiscover) ?? true;
    _multiScreen = p.getBool(_kMultiScreen) ?? false;
    _defaultCover = p.getBool(_kDefaultCover) ?? false;
    _readerMaxWidth = p.getInt(_kReaderMaxWidth) ?? readerMaxWidthDefault;
    _readerMaxWidthEnabled = p.getBool(_kReaderMaxWidthEnabled) ?? true;
    _pageAnimType = p.getString(_kPageAnimType) ?? 'cover';
    _loaded = true;
    notifyListeners();
  }

  Future<void> setBookshelfSort(BookshelfSort v) async {
    _bookshelfSort = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kBookshelfSort, v.id);
  }

  Future<void> setNightMode(NightMode v) async {
    _nightMode = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kNightMode, v.id);
  }

  Future<void> setChineseConvert(ChineseConvert v) async {
    _chineseConvert = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kChineseConvert, v.id);
  }

  Future<void> setTtsCacheCount(int v) async {
    _ttsCacheCount = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_kTtsCacheCount, v);
  }

  Future<void> setCommentStyle(CommentBubbleStyle v) async {
    _commentStyle = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kCommentStyle, v.id);
  }

  Future<void> setImageLimit(int v) async {
    _imageLimit = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_kImageLimit, v);
  }

  Future<void> setUseReplaceRule(bool v) async {
    _useReplaceRule = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kUseReplaceRule, v);
  }

  Future<void> setReaderMaxWidth(int v) async {
    _readerMaxWidth = v.clamp(readerMaxWidthMin, readerMaxWidthMax);
    notifyListeners();
    (await SharedPreferences.getInstance())
        .setInt(_kReaderMaxWidth, _readerMaxWidth);
  }

  Future<void> setReaderMaxWidthEnabled(bool v) async {
    _readerMaxWidthEnabled = v;
    notifyListeners();
    (await SharedPreferences.getInstance())
        .setBool(_kReaderMaxWidthEnabled, v);
  }

  Future<void> setReplaceLocalStorage(bool v) async {
    _replaceLocalStorage = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kReplaceLocalStorage, v);
  }

  Future<void> setTtsBackground(bool v) async {
    _ttsBackground = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kTtsBackground, v);
  }

  Future<void> setSearchThreadCount(int v) async {
    _searchThreadCount = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_kSearchThreadCount, v);
  }

  Future<void> setWebSocketEnabled(bool v) async {
    _webSocketEnabled = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kWebSocketEnabled, v);
  }

  Future<void> setShowSubscribe(bool v) async {
    _showSubscribe = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kShowSubscribe, v);
  }

  Future<void> setShowDiscover(bool v) async {
    _showDiscover = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kShowDiscover, v);
  }

  Future<void> setMultiScreen(bool v) async {
    _multiScreen = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kMultiScreen, v);
  }

  Future<void> setDefaultCover(bool v) async {
    _defaultCover = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kDefaultCover, v);
  }

  Future<void> setPageAnimType(String id) async {
    _pageAnimType = id;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kPageAnimType, id);
  }

  /// 按当前排序方式给书架排序（返回新列表，不改原列表）
  List<T> sortBooks<T>(
    List<T> books, {
    required String? Function(T) nameOf,
    required String? Function(T) authorOf,
    required int? Function(T) readTimeOf,
    required int? Function(T) updateTimeOf,
    required int? Function(T) orderOf,
  }) {
    final list = List<T>.of(books);
    switch (_bookshelfSort) {
      case BookshelfSort.readTime:
        // 最近读的排最前；从没读过（null / 0）的沉底，用更新时间兜底
        list.sort((a, b) => _cmpTime(
              readTimeOf(a) ?? updateTimeOf(a),
              readTimeOf(b) ?? updateTimeOf(b),
            ));
        break;
      case BookshelfSort.updateTime:
        list.sort((a, b) => _cmpTime(updateTimeOf(a), updateTimeOf(b)));
        break;
      case BookshelfSort.name:
        list.sort((a, b) => _cmpText(nameOf(a), nameOf(b)));
        break;
      case BookshelfSort.author:
        list.sort((a, b) => _cmpText(authorOf(a), authorOf(b)));
        break;
      case BookshelfSort.manual:
        // 手动排序：order 小的在前；都没有 order 时保持后端原顺序
        final withOrder = list.any((b) => orderOf(b) != null);
        if (withOrder) {
          list.sort((a, b) => (orderOf(a) ?? 0).compareTo(orderOf(b) ?? 0));
        }
        break;
    }
    return list;
  }

  /// 时间比较器（**降序**语义：时间较新的 a 排在前面）。
  ///
  /// 调用时按 `_cmpTime(a的值, b的值)` 自然顺序传入即可。
  /// 注意不要把参数反过来 —— 反了就变成「最旧的排最前」。
  static int _cmpTime(int? a, int? b) {
    final va = (a == null || a <= 0) ? -1 : a;
    final vb = (b == null || b <= 0) ? -1 : b;
    return vb.compareTo(va);
  }

  static int _cmpText(String? a, String? b) {
    final va = (a ?? '').trim();
    final vb = (b ?? '').trim();
    if (va.isEmpty && vb.isEmpty) return 0;
    if (va.isEmpty) return 1;
    if (vb.isEmpty) return -1;
    return va.compareTo(vb);
  }
}
