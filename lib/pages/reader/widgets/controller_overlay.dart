import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/tts_service.dart';
import 'reader_theme.dart';

/// 阅读器控制面板覆盖层 v2
///
/// 按 controller.md 文档拆为四层：
/// - TopInfoBar：返回、书名/章节/来源、刷新、更多
/// - FloatingCapsule：自动翻页/朗读/主题切换（普通/TTS/自动翻页三模式）
/// - ProgressStrip：上一章、章节滑杆、下一章
/// - BottomActionBar：目录、设置

// ============================================================
// 数据收口对象
// ============================================================

/// 胶囊模式枚举
enum ControllerCapsuleMode { normal, tts, autoPage }

/// 控制器视图数据——所有展示所需字段
class ReaderControllerViewData {
  final String bookName;
  final String chapterTitle;
  final String sourceName;
  final bool hasBookmark;
  final bool replaceRuleEnabled;
  final String themeName;
  final ControllerCapsuleMode capsuleMode;
  final TtsState ttsState;
  final double ttsRate;
  final double autoPageInterval;
  final int chapterIndex;
  final int totalChapters;
  final double? chapterSliderValue;
  final int ttsParagraphIndex;
  final int totalParagraphs;

  /// 当前书是否已在书架。不在时中间胶囊会多一个「+ 书架」按钮
  /// （对齐 3.41：点开控制栏能看到加号，已在书架的书就没有）。
  final bool inBookshelf;

  const ReaderControllerViewData({
    required this.bookName,
    required this.chapterTitle,
    required this.sourceName,
    required this.hasBookmark,
    required this.replaceRuleEnabled,
    required this.themeName,
    required this.capsuleMode,
    required this.ttsState,
    required this.ttsRate,
    required this.autoPageInterval,
    required this.chapterIndex,
    required this.totalChapters,
    this.chapterSliderValue,
    this.ttsParagraphIndex = -1,
    this.totalParagraphs = 0,
    this.inBookshelf = true,
  });
}

/// 控制器回调——所有用户操作
class ReaderControllerCallbacks {
  final VoidCallback onBack;
  final VoidCallback onShowMore;
  final VoidCallback onRefresh;
  final VoidCallback onToggleBookmark;
  final VoidCallback onStartAutoPage;
  final VoidCallback onStartTts;
  final VoidCallback onToggleTheme;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;
  final ValueChanged<double> onChapterSliderChanged;
  final ValueChanged<double> onChapterSliderEnd;
  final VoidCallback onShowChapterList;
  final VoidCallback onShowSettings;
  final VoidCallback onStopTts;
  final VoidCallback onPauseTts;
  final VoidCallback onResumeTts;
  final VoidCallback onShowTtsTimer;
  final VoidCallback onShowTtsSettings;

  /// 朗读栏上的 ⏮ / ⏭（上一段 / 下一段）
  final VoidCallback onTtsPrevParagraph;
  final VoidCallback onTtsNextParagraph;

  /// 朗读栏上的 « / »（上一章 / 下一章）
  final VoidCallback onTtsPrevChapter;
  final VoidCallback onTtsNextChapter;

  /// 朗读语速滑杆
  final ValueChanged<double> onTtsRateChanged;
  final VoidCallback onStopAutoPage;
  final VoidCallback onDecreaseAutoPageInterval;
  final VoidCallback onIncreaseAutoPageInterval;

  /// 点中间胶囊的「+ 书架」（书不在书架时才显示）
  final VoidCallback onAddToBookshelf;

  const ReaderControllerCallbacks({
    required this.onBack,
    required this.onShowMore,
    required this.onRefresh,
    required this.onToggleBookmark,
    required this.onStartAutoPage,
    required this.onStartTts,
    required this.onToggleTheme,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onChapterSliderChanged,
    required this.onChapterSliderEnd,
    required this.onShowChapterList,
    required this.onShowSettings,
    required this.onStopTts,
    required this.onPauseTts,
    required this.onResumeTts,
    required this.onShowTtsTimer,
    required this.onShowTtsSettings,
    required this.onTtsPrevParagraph,
    required this.onTtsNextParagraph,
    required this.onTtsPrevChapter,
    required this.onTtsNextChapter,
    required this.onTtsRateChanged,
    required this.onStopAutoPage,
    required this.onDecreaseAutoPageInterval,
    required this.onIncreaseAutoPageInterval,
    required this.onAddToBookshelf,
  });
}

// ============================================================
// 主组件
// ============================================================

class ControllerOverlay extends StatefulWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;

  /// 阅读主题 —— 控制栏的底色与文字色全部跟随它。
  ///
  /// 【为什么必须跟随主题】原来顶部和底部用的是写死的黑色半透明
  /// （0.45 / 0.88）。在护眼绿、羊皮纸这类浅色主题下，黑条会糊住正文，
  /// 观感就是「有遮挡、颜色也不好」；而且色块和正文之间有一道硬分界，
  /// 看起来像「上面和底部各留了一条空隙」。
  /// 改成跟阅读背景同色之后，控制栏与正文融为一体，两个问题一起消失。
  final ReaderTheme theme;

  /// 自动隐藏延时；传 null 表示不自动隐藏（自动翻页模式下控制栏常驻）。
  ///
  /// 【为什么把倒计时放在控制栏自己身上】
  /// 上一版是在页面的 `_showControllerTemporarily()` 里起 `Timer`。
  /// 那条路径确实会走到，但「倒计时」这件事被绑在了一个**调用点**上 ——
  /// 任何一次意外的 `cancel`、或将来新增一条显示路径，都会让控制栏
  /// 永久盖在正文上（用户反馈「还是无法自动隐藏引导条」）。
  /// 现在改成由 `ControllerOverlay` 自己持有：它只会在控制栏可见时存在于
  /// 树上，`initState` 里就排好倒计时 —— 等价于「只要它被渲染出来，
  /// 就一定会自己收起来」。
  final Duration? autoHideDelay;

  /// 用户与控制栏交互（翻页 / 拉进度 / 切主题…）时由页面 +1，
  /// 用来把倒计时往后推。
  final int restartToken;

  /// 倒计时结束的回调（页面负责把 showController 置 false）
  final VoidCallback? onAutoHide;

  const ControllerOverlay({
    Key? key,
    required this.data,
    required this.callbacks,
    required this.theme,
    this.autoHideDelay,
    this.restartToken = 0,
    this.onAutoHide,
  }) : super(key: key);

  @override
  State<ControllerOverlay> createState() => _ControllerOverlayState();
}

class _ControllerOverlayState extends State<ControllerOverlay> {
  Timer? _autoHideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleAutoHide();
  }

  @override
  void didUpdateWidget(ControllerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 交互或模式切换会换 token / 延时，倒计时重新开始。
    // 注意：Provider 通知导致的普通重建不会换 token，所以倒计时不会被
    // 高频刷新（时间/电量每分钟一次）反复推后。
    if (oldWidget.restartToken != widget.restartToken ||
        oldWidget.autoHideDelay != widget.autoHideDelay) {
      _scheduleAutoHide();
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    super.dispose();
  }

  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    final delay = widget.autoHideDelay;
    if (delay == null) return;
    _autoHideTimer = Timer(delay, () {
      if (!mounted) return;
      widget.onAutoHide?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final callbacks = widget.callbacks;
    final theme = widget.theme;
    return Stack(
      children: [
        // 顶部信息栏
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _TopInfoBar(data: data, callbacks: callbacks, theme: theme),
        ),

        // 底部整块：悬浮胶囊 + 进度条 + 功能栏
        //
        // 【为什么三者要一起从底边往上堆】
        // 原来胶囊是独立的 `Positioned(bottom: 136)`，而 136 这个数字是拍脑袋
        // 定的 —— 底部整块的实际高度是「手势条 + 进度条 + 功能栏」，
        // 在 iOS/Android 上约 140px，于是胶囊正好压在「上一章/下一章」那一行上
        // （反馈截图「自动/朗读/浅色」那排和滑杆重叠）。
        // 现在把胶囊放进同一个 Column，它会自动排在面板**上方**，
        // 不管手势条多高、字体多大都不会再重叠。
        //
        // Container 包在 SafeArea **外面** —— 这样系统手势条那一块也会铺上主题色。
        // 反过来写（SafeArea 在外）的话，手势条区域是透明的，会透出下面的正文，
        // 看起来就是「底部没铺满」。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // TTS 模式下播放控制已经在下面的面板里了，中间胶囊不再重复出现
              if (data.capsuleMode != ControllerCapsuleMode.tts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _FloatingCapsule(
                      data: data, callbacks: callbacks, theme: theme),
                ),
              Container(
                color: theme.background,
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 4),
                      _ProgressStrip(
                          data: data, callbacks: callbacks, theme: theme),
                      const SizedBox(height: 2),
                      _BottomActionBar(
                          data: data, callbacks: callbacks, theme: theme),
                      const SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================
// 顶部信息栏
// ============================================================

class _TopInfoBar extends StatelessWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _TopInfoBar({
    required this.data,
    required this.callbacks,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    // 深色主题下纯白按钮会刺眼，所以「更多」的底色也跟着主题走
    final isDark = theme.background.computeLuminance() < 0.5;
    final pillBg = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.72);

    // Container 包在 SafeArea **外面**：底色要铺到状态栏区域。
    // 原来是 SafeArea 在外、Container 在内，状态栏那块是透明的，
    // 正文会从状态栏下面透出来 —— 观感就是「上面留了一条空隙」。
    return Container(
      color: theme.background,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ---- 第一行：返回 + 书名 + 更多 ----
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_new,
                        color: theme.text, size: 20),
                    onPressed: callbacks.onBack,
                    padding: const EdgeInsets.all(8),
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    tooltip: '返回',
                  ),
                  Expanded(
                    child: Text(
                      data.bookName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: callbacks.onShowMore,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: pillBg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        '更多',
                        style: TextStyle(color: theme.text, fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // ---- 第二行：章节 ----
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(
                  children: [
                    Text('章节：',
                        style: TextStyle(
                            color: theme.secondaryText, fontSize: 12)),
                    Expanded(
                      child: Text(
                        data.chapterTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.text, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              // ---- 第三行：来源 + 刷新 ----
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(
                  children: [
                    Text('来源：',
                        style: TextStyle(
                            color: theme.secondaryText, fontSize: 12)),
                    Expanded(
                      child: Text(
                        data.sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.text, fontSize: 12),
                      ),
                    ),
                    InkWell(
                      onTap: callbacks.onRefresh,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        child: Text(
                          '刷新',
                          style: TextStyle(
                            // 替换规则生效时高亮，提示「刷新会走净化」
                            color: data.replaceRuleEnabled
                                ? const Color(0xFF00A88F)
                                : theme.secondaryText,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 中部悬浮胶囊
// ============================================================

class _FloatingCapsule extends StatelessWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _FloatingCapsule({
    required this.data,
    required this.callbacks,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = theme.background.computeLuminance() < 0.5;
    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Container(
          key: ValueKey(data.capsuleMode),
          margin: const EdgeInsets.symmetric(horizontal: 48),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            // 浅色主题用白胶囊（对齐 3.41）；深色主题下纯白太刺眼，改成半透明白
            color: isDark
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(40),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          // 胶囊里的图标和文字统一继承主题色，省得每个按钮各写一套颜色
          child: IconTheme(
            data: IconThemeData(color: theme.text),
            child: DefaultTextStyle(
              style: TextStyle(color: theme.text),
              child: _buildCapsuleContent(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCapsuleContent() {
    switch (data.capsuleMode) {
      case ControllerCapsuleMode.tts:
        return _buildTtsCapsule();
      case ControllerCapsuleMode.autoPage:
        return _buildAutoPageCapsule();
      case ControllerCapsuleMode.normal:
      return _buildNormalCapsule();
    }
  }

  /// 普通模式：自动翻页 / 朗读 / 深浅切换
  /// （书不在书架时，末尾多一个「+ 书架」）
  Widget _buildNormalCapsule() {
    final isLight = data.themeName == 'light';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CapsuleButton(
          icon: Icons.auto_awesome_motion_outlined,
          label: '自动',
          onTap: callbacks.onStartAutoPage,
        ),
        _CapsuleDivider(),
        _CapsuleButton(
          icon: Icons.play_circle_outline,
          label: '朗读',
          onTap: callbacks.onStartTts,
        ),
        _CapsuleDivider(),
        _CapsuleButton(
          icon: isLight ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
          label: isLight ? '深色' : '浅色',
          onTap: callbacks.onToggleTheme,
        ),
        // 已在书架的书不显示加号（对齐 3.41）
        if (!data.inBookshelf) ...[
          _CapsuleDivider(),
          _CapsuleButton(
            icon: Icons.add_circle_outline,
            label: '书架',
            onTap: callbacks.onAddToBookshelf,
          ),
        ],
      ],
    );
  }

  /// TTS 模式：停止 / 暂停继续
  Widget _buildTtsCapsule() {
    final isPaused = data.ttsState == TtsState.paused;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CapsuleButton(
          icon: Icons.stop_circle_outlined,
          label: '停止',
          onTap: callbacks.onStopTts,
        ),
        _CapsuleDivider(),
        _CapsuleButton(
          icon: isPaused ? Icons.play_circle_filled : Icons.pause_circle_filled,
          label: isPaused ? '继续' : '暂停',
          onTap: isPaused ? callbacks.onResumeTts : callbacks.onPauseTts,
        ),
      ],
    );
  }

  /// 自动翻页模式：减速 / 秒数 / 加速 / 停止
  Widget _buildAutoPageCapsule() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CapsuleButton(
          icon: Icons.remove,
          label: '减速',
          onTap: callbacks.onDecreaseAutoPageInterval,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${data.autoPageInterval.toStringAsFixed(0)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Text(
                '秒/页',
                style: TextStyle(fontSize: 10),
              ),
            ],
          ),
        ),
        _CapsuleButton(
          icon: Icons.add,
          label: '加速',
          onTap: callbacks.onIncreaseAutoPageInterval,
        ),
        _CapsuleDivider(),
        _CapsuleButton(
          icon: Icons.stop_circle_outlined,
          label: '停止',
          onTap: callbacks.onStopAutoPage,
        ),
      ],
    );
  }
}

// ============================================================
// 进度条行
// ============================================================

class _ProgressStrip extends StatelessWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _ProgressStrip({
    required this.data,
    required this.callbacks,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    // 原来写死青绿 + 灰色轨道，在护眼绿/羊皮纸这些主题下很突兀；
    // 改成跟着主题的正文色/次要色走。
    final thumbColor = theme.text.withValues(alpha: 0.55);
    final trackColor = theme.secondaryText.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // 上一章
          SizedBox(
            width: 56,
            child: TextButton(
              onPressed: data.chapterIndex > 0 ? callbacks.onPrevChapter : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('上一章',
                  style: TextStyle(fontSize: 12, color: theme.text)),
            ),
          ),
          // 滑杆
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: thumbColor,
                thumbColor: thumbColor,
                inactiveTrackColor: trackColor,
              ),
              child: Slider(
                value: (data.chapterSliderValue ?? data.chapterIndex.toDouble())
                    .clamp(0, (data.totalChapters - 1).toDouble()),
                min: 0,
                max: data.totalChapters <= 1
                    ? 1
                    : (data.totalChapters - 1).toDouble(),
                onChanged: callbacks.onChapterSliderChanged,
                onChangeEnd: callbacks.onChapterSliderEnd,
              ),
            ),
          ),
          // 下一章
          SizedBox(
            width: 56,
            child: TextButton(
              onPressed: data.chapterIndex < data.totalChapters - 1
                  ? callbacks.onNextChapter
                  : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('下一章',
                  style: TextStyle(fontSize: 12, color: theme.text)),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 底部功能栏
// ============================================================

class _BottomActionBar extends StatelessWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _BottomActionBar({
    required this.data,
    required this.callbacks,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    // TTS 模式下显示 TTS 专用底部
    if (data.capsuleMode == ControllerCapsuleMode.tts) {
      return _buildTtsBottom();
    }
    return _buildNormalBottom();
  }

  Widget _buildNormalBottom() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _BottomEntry(
            icon: Icons.list_alt_outlined,
            label: '目录',
            theme: theme,
            onTap: callbacks.onShowChapterList,
          ),
          _BottomEntry(
            icon: Icons.tune_outlined,
            label: '设置',
            theme: theme,
            onTap: callbacks.onShowSettings,
          ),
        ],
      ),
    );
  }

  /// TTS 模式底部（对齐 3.41 的朗读界面），三行：
  ///
  /// ```
  /// «  ⏮  ⏸/▶  ⏹  ⏭  »
  /// 朗读语速 0.5 ────────  [⏱ 定时]
  ///      目录        设置
  /// ```
  ///
  /// 原来只有「定时 / 目录 / 听书设置」三个入口，播放控制塞在中间那颗
  /// 悬浮胶囊里（只有「停止/暂停」），切段、切章都得退出去。
  Widget _buildTtsBottom() {
    final isPaused = data.ttsState == TtsState.paused;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- 第一行：播放控制 ----
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _TtsIconButton(
                icon: Icons.keyboard_double_arrow_left,
                size: 22,
                color: theme.text,
                onTap: callbacks.onTtsPrevChapter,
              ),
              _TtsIconButton(
                icon: Icons.skip_previous,
                size: 24,
                color: theme.text,
                onTap: callbacks.onTtsPrevParagraph,
              ),
              _TtsIconButton(
                icon: isPaused ? Icons.play_arrow : Icons.pause,
                size: 30,
                color: theme.text,
                onTap: isPaused ? callbacks.onResumeTts : callbacks.onPauseTts,
              ),
              _TtsIconButton(
                icon: Icons.stop,
                size: 26,
                color: theme.text,
                onTap: callbacks.onStopTts,
              ),
              _TtsIconButton(
                icon: Icons.skip_next,
                size: 24,
                color: theme.text,
                onTap: callbacks.onTtsNextParagraph,
              ),
              _TtsIconButton(
                icon: Icons.keyboard_double_arrow_right,
                size: 22,
                color: theme.text,
                onTap: callbacks.onTtsNextChapter,
              ),
            ],
          ),
          const SizedBox(height: 2),
          // ---- 第二行：语速 + 定时 ----
          Row(
            children: [
              const SizedBox(width: 6),
              Text(
                '朗读语速 ${data.ttsRate.toStringAsFixed(1)}',
                style: TextStyle(fontSize: 12, color: theme.secondaryText),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: theme.text.withValues(alpha: 0.55),
                    thumbColor: theme.text.withValues(alpha: 0.55),
                    inactiveTrackColor:
                        theme.secondaryText.withValues(alpha: 0.3),
                  ),
                  child: Slider(
                    value: data.ttsRate.clamp(0.1, 1.0),
                    min: 0.1,
                    max: 1.0,
                    divisions: 9,
                    onChanged: callbacks.onTtsRateChanged,
                  ),
                ),
              ),
              InkWell(
                onTap: callbacks.onShowTtsTimer,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.text.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.timer_outlined, size: 14, color: theme.text),
                      const SizedBox(width: 4),
                      Text('定时',
                          style: TextStyle(fontSize: 12, color: theme.text)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
          const SizedBox(height: 2),
          // ---- 第三行：目录 / 设置 ----
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _BottomEntry(
                icon: Icons.menu_book_outlined,
                label: '目录',
                theme: theme,
                onTap: callbacks.onShowChapterList,
              ),
              _BottomEntry(
                icon: Icons.settings_outlined,
                label: '设置',
                theme: theme,
                onTap: callbacks.onShowTtsSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 朗读控制栏上的图标按钮（颜色由调用方显式给，底部区域没有 IconTheme）
class _TtsIconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback onTap;

  const _TtsIconButton({
    required this.icon,
    required this.size,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      iconSize: size,
      color: color,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: const EdgeInsets.all(4),
      icon: Icon(icon),
    );
  }
}

// ============================================================
// 通用小组件
// ============================================================

/// 胶囊内按钮
class _CapsuleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _CapsuleButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 颜色不写死 —— 由 _FloatingCapsule 包在外面的 IconTheme 按当前阅读主题
    // 注入，深色主题下才不会出现「浅底浅字」看不清的情况
    final tint = IconTheme.of(context).color;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: tint, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: tint?.withValues(alpha: 0.65),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 胶囊内分隔线
class _CapsuleDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // 跟随外层 IconTheme（在 _FloatingCapsule 里按阅读主题注入）
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: IconTheme.of(context).color?.withValues(alpha: 0.2),
    );
  }
}

/// 底部功能入口
class _BottomEntry extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final ReaderTheme theme;

  const _BottomEntry({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 原来是写死的白色 —— 在护眼绿这类浅色主题下基本看不见
            Icon(icon, color: theme.text, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(color: theme.secondaryText, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
