import 'package:flutter/material.dart';

import 'engine/engine.dart';
import 'widgets/reader_fonts.dart';
import 'widgets/reader_theme.dart';
import 'widgets/controller_overlay.dart';

/// 翻页动画类型
///
/// 与设置面板「翻页」一行对应：
/// 覆盖 / 仿真 / 翻书 / 左右 是主选项，滚动 / 无 收在「更多设置」里。
enum PageAnimType {
  cover('cover', '覆盖'),
  simulation('simulation', '仿真'),
  flipbook('flipbook', '翻书'),
  slide('slide', '左右'),
  scroll('scroll', '滚动'),
  none('none', '无');

  const PageAnimType(this.id, this.label);

  final String id;
  final String label;

  /// 是否走竖向滚动的 ScrollReader（只有「滚动」）
  bool get usesScrollReader => this == PageAnimType.scroll;

  /// 是否瞬间切换（无动画）
  bool get instantTurn => this == PageAnimType.none;

  Axis get axis => Axis.horizontal;

  bool get disableUserScroll => this == PageAnimType.none;

  /// 是否走手势驱动的「手动分页」渲染（覆盖 / 仿真 / 翻书 / 无）
  bool get usesManualPaging =>
      this == PageAnimType.cover ||
      this == PageAnimType.simulation ||
      this == PageAnimType.flipbook ||
      this == PageAnimType.none;

  /// 主面板上直接展示的翻页模式。
  ///
  /// 【为什么「滚动」「无」挪进来了】原来这两个收在「更多设置」抽屉里，
  /// 于是「翻页」在两处各有一份选项，看起来像重复设置。现在统一收到主面板，
  /// 抽屉里不再出现「翻页」一行。
  static const List<PageAnimType> primaryChoices = [
    PageAnimType.cover,
    PageAnimType.simulation,
    PageAnimType.flipbook,
    PageAnimType.slide,
    PageAnimType.scroll,
    PageAnimType.none,
  ];

  static PageAnimType fromId(String? id) {
    // 兼容历史配置：旧版本把「仿真」存成 book、左右存成 horizontal、
    // 滚动存成 vertical。注意 'vertical' 现在仍然映射到 scroll，
    // 因为新的翻页枚举里没有单独的「上下」。
    switch (id) {
      case 'book':
        return PageAnimType.simulation;
      case 'horizontal':
        return PageAnimType.slide;
      case 'vertical':
        return PageAnimType.scroll;
    }
    for (final type in PageAnimType.values) {
      if (type.id == id) return type;
    }
    return PageAnimType.cover;
  }

  /// 旧版本按序号存的是 int
  static PageAnimType fromLegacyIndex(int index) {
    switch (index) {
      case 0:
        return PageAnimType.cover;
      case 1:
        return PageAnimType.slide;
      case 2:
        return PageAnimType.simulation;
      case 3:
        return PageAnimType.scroll;
      case 4:
        return PageAnimType.none;
      default:
        return PageAnimType.cover;
    }
  }
}

/// 阅读器核心状态
///
/// 将原 _ReaderPageState 中散落的全局变量集中到此类，
/// 便于跨组件共享和调试。

class ReaderState with ChangeNotifier {
  // ---- 视图状态 ----
  bool showController = false;
  bool showAutoPageControls = true;
  bool loadingDisplayedChapter = false;
  bool initialChapterOpened = false;

  // ---- 阅读设置 ----
  //
  // 【数值来源】官方客户端（后端 Web 端同款）实测：屏幕宽 1179px 时
  // 1 个字宽 83.5px，即字号 ≈ 屏宽的 7.08%；行距 126/83.5 ≈ 1.5；
  // 左右边距 51px ≈ 0.61em；段间距 21px ≈ 0.25em。
  // 按 393pt 宽的常见机型折算：字号 28、边距 16、段间距 7。
  // 用户要求 App 排版与后端 Web 端统一，所以这些默认值就是照它定的。
  double fontSize = 28.0;
  double lineHeight = 1.5;
  double autoPageInterval = 12.0;
  bool autoNext = true;
  String theme = 'green';
  String pageMode = 'paged';
  PageAnimType pageAnimType = PageAnimType.cover;

  /// 屏幕亮度（1.0 = 不压暗，0.1 = 最暗）。
  /// 实现方式是盖一层黑色蒙版，不动系统亮度。
  double brightness = 1.0;

  /// 「自动」亮度 = 不盖压暗蒙版，完全交给系统亮度。
  ///
  /// 【为什么自动就是 1.0】我们没有也不打算引入读写系统亮度的插件
  /// （本机没有 Flutter SDK，新依赖无法验证）。压暗蒙版本质是「在系统亮度
  /// 之上再压一档」，自动档的语义自然是「不压」—— 和轻阅时光「跟随系统」
  /// 的效果一致。
  bool brightnessAuto = false;

  /// 字体 id，见 widgets/reader_fonts.dart
  String fontFamily = 'default';

  /// 正文加粗
  bool boldText = false;

  /// 段评（段落评论）：是否在正文里显示并允许点击气泡
  bool showParagraphComment = true;

  // ---- 更多设置（默认值） ----
  bool volumeKeyFlip = false; // 音量键翻页
  bool showBottomBar = true; // 底部区域（时间/电量/页码）
  bool showTopBar = true; // 顶部区域（章节序号/章节名）

  /// 屏幕常亮档位：0 关 / -1 常亮 / 5 / 10（分钟，倒计时到点自动放屏）。
  int wakelockMinutes = -1;

  /// 页脚「显示进度」四档：0 关 / 1 本章 / 2 全书 / 3 本章+全书。
  int progressMode = 1;

  /// 旧「显示页码」开关的兼容视图：进度关 = 不显示页码。
  bool get showPageNumber => progressMode != 0;

  // ---- 更多设置·排版与页眉页脚 ----

  /// 隐藏正文顶部的大标题段（每章第一页居中加粗的章节名）。
  /// 页眉那行小字不受影响 —— 归 showTopBar 管。
  bool hideTitle = false;

  /// 大标题对齐：0 左 / 1 中 / 2 右。
  int titleAlign = 1;

  /// 页眉/页脚与正文之间画一条细分隔线。
  bool showHeaderFooterDivider = false;

  /// 页脚左侧的时间。
  bool showFooterTime = true;

  /// 页脚右侧的电量。
  bool showFooterBattery = true;

  /// 本章最后一页内容不满一页时，顶部补空隙让文字贴底（轻阅时光「底部对齐」）。
  bool bottomAlignLastPage = false;

  // ---- 更多设置·系统 ----

  /// 阅读页内隐藏系统状态栏。
  bool hideStatusBar = false;

  /// 锁定竖屏。
  bool lockOrientation = false;

  // ---- 更多设置·交互 ----

  /// 底部章节滑杆按「分页」拖动（false = 按章节）。
  bool sliderByPage = false;

  /// 正文区域上滑退出阅读页。
  bool swipeUpExit = false;

  /// 正文区域下滑加/减书签。
  bool swipeDownBookmark = false;

  /// 目录弹层默认倒序。
  bool tocReversed = false;

  // ---- 间距设置 ----
  double paragraphSpacing = 7.0; // 段间距 (px)
  double firstLineIndent = 2.0; // 首行缩进 (字符数)
  double horizontalPadding = 16.0; // 左右边距 (px)
  double topPadding = 10.0; // 上方边距 (px)

  // ---- 章节状态 ----
  String displayedContent = '';
  int chapterRequestSerial = 0;
  int laidOutChapterIndex = -1;
  int chapterPosition = 0;
  int currentPage = 0;
  int? pendingChapterPosition;
  bool pendingOpenChapterAtEnd = false;

  // ---- 排版结果 ----
  List<ReaderParagraph> paragraphs = [];
  List<PageSlice> pages = [];
  Map<int, int> paragraphPageLookup = {};
  ChapterLayout? currentLayout;

  // ---- TTS ----
  bool ttsReading = false;
  bool continueTtsOnNextChapter = false;
  int ttsParagraphIndex = -1;
  int? ttsSleepMinutes;

  /// 听书设置里的三个开关（对齐 3.41 的「听书设置」面板）。
  ///
  /// - [ttsAllowPageTurn]：朗读时页面是否跟着朗读位置自动翻页；
  /// - [ttsShowChapterSwitch]：本章读完后是否自动切到下一章；
  /// - [ttsDelayPageTurn]：翻页是否延后到当前段读完（关掉就是紧跟高亮走）。
  bool ttsAllowPageTurn = true;
  bool ttsShowChapterSwitch = true;
  bool ttsDelayPageTurn = true;

  // ---- 自动翻页 ----
  bool autoPageRunning = false;

  // ---- 书籍类型 ----
  bool isComic = false;

  // ---- 元信息 ----
  DateTime now = DateTime.now();
  int? batteryLevel;
  double? chapterSliderValue;

  /// 「菜单滑动条按分页」时，分页滑杆拖动中的瞬时值（松手即清 null）。
  double? pageSliderValue;

  // ---- 视口 ----
  Size? pagedViewportSize;

  // ---- 缓存 ----
  final Map<String, ChapterLayout> layoutCache = {};

  // ---- 预排版缓存 ----
  /// 预排版的下一章布局（包含 content 和 chapterTitle）
  ChapterLayout? prefetchedNextLayout;
  String? prefetchedNextContent;
  String? prefetchedNextTitle;
  int prefetchedNextChapterIndex = -1;

  /// 预排版的上一章布局
  ChapterLayout? prefetchedPrevLayout;
  String? prefetchedPrevContent;
  String? prefetchedPrevTitle;
  int prefetchedPrevChapterIndex = -1;

  void notify() => notifyListeners();

  // ---- 便捷方法 ----

  ReaderTheme get currentTheme => ReaderTheme.byName(theme);

  /// 当前正文字体族（null = 系统默认）
  String? get textFontFamily => ReaderFont.familyOf(fontFamily);

  /// 正文字重
  FontWeight get textFontWeight =>
      boldText ? FontWeight.w600 : FontWeight.normal;

  /// [titleAlign] 的 TextAlign 版（0 左 / 1 中 / 2 右）。
  TextAlign get titleTextAlign {
    switch (titleAlign) {
      case 0:
        return TextAlign.left;
      case 2:
        return TextAlign.right;
      default:
        return TextAlign.center;
    }
  }

  /// 屏幕压暗蒙版透明度（0 = 不压暗）
  double get dimOpacity =>
      brightnessAuto ? 0.0 : ((1.0 - brightness) * 0.85).clamp(0.0, 0.85);

  bool get isScrollMode => isComic || pageAnimType.usesScrollReader;

  void applyPageAnimType(PageAnimType type) {
    pageAnimType = type;
    pageMode = type.usesScrollReader ? 'scroll' : 'paged';
  }

  int displayedChapterIndex(int bookDurChapterIndex) {
    if (laidOutChapterIndex >= 0) return laidOutChapterIndex;
    return bookDurChapterIndex;
  }

  bool hasPreviousChapter(int chapterIndex) => chapterIndex > 0;

  bool hasNextChapter(int chapterIndex, int totalChapters) =>
      chapterIndex < totalChapters - 1;

  /// 消费待定位置
  void consumePendingPosition() {
    pendingChapterPosition = null;
    pendingOpenChapterAtEnd = false;
  }

  /// 解析目标章节位置
  ///
  /// 优先级：
  /// 1. openAtEnd 标记 → 返回极大值（映射到最后一页）
  /// 2. pendingChapterPosition → 直接使用
  /// 3. 如果正在请求的章节与已排版章节相同 → 使用当前 chapterPosition
  /// 4. 如果请求的章节与 book 保存的章节相同 → 使用保存的位置
  /// 5. 默认 → 0（首页）
  int resolveTargetChapterPosition(
      int bookDurChapterIndex, int? bookDurChapterPos) {
    // 最高优先级：跳到末尾
    if (pendingOpenChapterAtEnd) {
      return 1 << 30;
    }
    // 次高优先级：显式指定的位置
    if (pendingChapterPosition != null) {
      return pendingChapterPosition!;
    }
    // 以下分支只在 _rebuildPages（同章节重排）时才会走到
    // 对于 _openChapter（新章节），前两个分支一定能覆盖
    if (laidOutChapterIndex >= 0 &&
        laidOutChapterIndex == displayedChapterIndex(bookDurChapterIndex)) {
      return chapterPosition;
    }
    if (bookDurChapterIndex == displayedChapterIndex(bookDurChapterIndex)) {
      final savedPos = bookDurChapterPos ?? 0;
      if (savedPos > 1) return savedPos;
    }
    return 0;
  }

  int pageIndexForPosition(int position) {
    if (pages.isEmpty) return 0;
    if (position >= (1 << 29)) return pages.length - 1;
    for (var i = 0; i < pages.length; i++) {
      if (position <= pages[i].endPosition) return i;
    }
    return pages.length - 1;
  }

  /// 页脚「进度」文案的四档计算（静态版，PagedReader 按页调用）。
  ///
  /// [mode]：0 关（空串）/ 1 本章（页码 x/y）/ 2 全书（章节百分比）/ 3 两個都要。
  /// [currentDisplay] 是正在渲染的那一页（1-based），[totalPages] 本章总页数。
  static String progressLabel({
    required int mode,
    required int currentDisplay,
    required int totalPages,
    required int chapterIndex,
    required int totalChapters,
  }) {
    final total = totalPages <= 0 ? 1 : totalPages;
    final current = currentDisplay.clamp(1, total);
    final chapterPart = '$current/$total';
    String bookPart() {
      if (totalChapters <= 0) return '--';
      final pct =
          (chapterIndex + 1).clamp(0, totalChapters) / totalChapters * 100;
      return '${pct.toStringAsFixed(1)}%';
    }

    switch (mode) {
      case 0:
        return '';
      case 2:
        return bookPart();
      case 3:
        return '$chapterPart  ${bookPart()}';
      case 1:
      default:
        return chapterPart;
    }
  }

  /// 页脚「进度」那一格的文案，按 [progressMode] 出四档（见 [progressLabel]）。
  ///
  /// [displayPage]/[displayTotal] 由分页渲染器按「正在画的这一页」传入
  /// （1-based）；不传则用当前页。滚动模式的「本章」仍是 1/段数。
  String pageIndicatorLabel({
    int chapterIndex = 0,
    int totalChapters = 0,
    int displayPage = 0,
    int displayTotal = 0,
  }) {
    if (isScrollMode) {
      // 滚动模式没有「页」，本章进度固定 1/段数；全书档仍按章节百分比。
      final total = paragraphs.isEmpty ? 1 : paragraphs.length;
      return progressLabel(
        mode: progressMode,
        currentDisplay: 1,
        totalPages: total,
        chapterIndex: chapterIndex,
        totalChapters: totalChapters,
      );
    }
    final total = displayTotal > 0 ? displayTotal : pages.length;
    final current = displayPage > 0 ? displayPage : currentPage + 1;
    return progressLabel(
      mode: progressMode,
      currentDisplay: current,
      totalPages: total,
      chapterIndex: chapterIndex,
      totalChapters: totalChapters,
    );
  }

  String formatTime() {
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String batteryLabel() => batteryLevel == null ? '--' : '$batteryLevel%';

  /// 胶囊模式——控制器根据此值切换悬浮胶囊内容
  ControllerCapsuleMode get capsuleMode {
    if (autoPageRunning) return ControllerCapsuleMode.autoPage;
    if (ttsReading || ttsParagraphIndex >= 0) return ControllerCapsuleMode.tts;
    return ControllerCapsuleMode.normal;
  }
}
