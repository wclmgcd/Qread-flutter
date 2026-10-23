import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/tts_service.dart';
import 'reader_theme.dart';

/// 阅读器控制面板覆盖层 v3 —— 视觉对齐轻阅时光：
///
/// - 顶部：左侧白圆钮「返回」，右侧 4 个白圆钮（批量下载/换源/刷新/更多）
/// - 右侧竖排 3 个白圆钮：自动阅读 / 朗读 / 夜间
/// - 底部：章节滑杆 pill（‹ slider ›）+ 工具 pill（目录/字体/背景/更多）
/// - TTS 模式：底部换成朗读控制卡；右侧竖排隐藏（播放控制都在卡片里）
///
/// 轻阅时光底部工具条中间的 AI 入口按用户要求不做。

// ============================================================
// 数据收口对象
// ============================================================

/// 底部模式枚举
enum ControllerCapsuleMode { normal, tts, autoPage }

/// 控制器视图数据——所有展示所需字段
class ReaderControllerViewData {
  final ControllerCapsuleMode capsuleMode;
  final TtsState ttsState;
  final double ttsRate;
  final int chapterIndex;
  final int totalChapters;
  final double? chapterSliderValue;

  const ReaderControllerViewData({
    required this.capsuleMode,
    required this.ttsState,
    required this.ttsRate,
    required this.chapterIndex,
    required this.totalChapters,
    this.chapterSliderValue,
  });
}

/// 控制器回调——所有用户操作
class ReaderControllerCallbacks {
  // ---- 顶部 ----
  final VoidCallback onBack;
  final VoidCallback onBatchDownload;
  final VoidCallback onChangeSource;
  final VoidCallback onRefresh;
  final VoidCallback onShowMore;

  // ---- 右侧竖排 ----
  final VoidCallback onStartAutoPage;
  final VoidCallback onStartTts;
  final VoidCallback onToggleTheme;

  // ---- 章节滑杆 ----
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;
  final ValueChanged<double> onChapterSliderChanged;
  final ValueChanged<double> onChapterSliderEnd;

  // ---- 底部工具 ----
  final VoidCallback onShowChapterList;

  /// 「字体」—— 打开界面设置面板
  final VoidCallback onShowSettings;

  /// 「背景」—— 打开背景设置面板
  final VoidCallback onShowBackground;

  /// 「更多」齿轮 —— 打开更多设置整页
  final VoidCallback onShowMoreSettings;

  // ---- TTS ----
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

  const ReaderControllerCallbacks({
    required this.onBack,
    required this.onBatchDownload,
    required this.onChangeSource,
    required this.onRefresh,
    required this.onShowMore,
    required this.onStartAutoPage,
    required this.onStartTts,
    required this.onToggleTheme,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onChapterSliderChanged,
    required this.onChapterSliderEnd,
    required this.onShowChapterList,
    required this.onShowSettings,
    required this.onShowBackground,
    required this.onShowMoreSettings,
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
  });
}

// ============================================================
// 主组件
// ============================================================

class ControllerOverlay extends StatefulWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;

  /// 阅读主题 —— 圆钮/pill 的底色与图标色按它的明暗切换。
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
    final isTts = data.capsuleMode == ControllerCapsuleMode.tts;
    return Stack(
      children: [
        // 顶部：返回 + 4 个功能圆钮
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _TopBar(callbacks: callbacks, theme: theme),
        ),

        // 右侧竖排：自动阅读 / 朗读 / 夜间（TTS 时播放控制都在底部卡片里，隐藏）
        if (!isTts)
          Positioned(
            right: 10,
            top: 0,
            bottom: 0,
            child: _SideColumn(callbacks: callbacks, theme: theme),
          ),

        // 底部：章节滑杆 pill + 工具 pill（或 TTS 控制卡）
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SliderPill(data: data, callbacks: callbacks, theme: theme),
                  const SizedBox(height: 10),
                  if (isTts)
                    _TtsBottomCard(
                        data: data, callbacks: callbacks, theme: theme)
                  else
                    _ToolbarPill(callbacks: callbacks, theme: theme),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// 主题相关的公共颜色
// ============================================================

/// 圆钮 / pill 的配色。浅色主题用白底深图标（对齐轻阅时光），
/// 深色主题用深灰底浅图标，免得一颗白丸子糊在深色正文上。
class _ChromeColors {
  final Color pill;
  final Color icon;
  final Color sliderActive;
  final Color sliderInactive;

  _ChromeColors(ReaderTheme theme)
      : pill = theme.background.computeLuminance() < 0.5
            ? const Color(0xFF23272E)
            : Colors.white,
        icon = theme.background.computeLuminance() < 0.5
            ? Colors.white70
            : const Color(0xFF333333),
        sliderActive = const Color(0xFF55A0E8),
        sliderInactive = theme.background.computeLuminance() < 0.5
            ? Colors.white24
            : const Color(0xFFD8DCE2);
}

/// 圆形按钮（顶部 / 右侧竖排共用）
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final _ChromeColors colors;
  final String? tooltip;

  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.colors,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: colors.pill,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: colors.icon),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 顶部按钮行
// ============================================================

class _TopBar extends StatelessWidget {
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _TopBar({required this.callbacks, required this.theme});

  @override
  Widget build(BuildContext context) {
    final colors = _ChromeColors(theme);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        child: Row(
          children: [
            _CircleButton(
              icon: Icons.arrow_back_ios_new,
              onTap: callbacks.onBack,
              colors: colors,
              tooltip: '返回',
            ),
            const Spacer(),
            _CircleButton(
              icon: Icons.file_download_outlined,
              onTap: callbacks.onBatchDownload,
              colors: colors,
              tooltip: '批量下载',
            ),
            const SizedBox(width: 8),
            _CircleButton(
              icon: Icons.swap_horiz,
              onTap: callbacks.onChangeSource,
              colors: colors,
              tooltip: '换源',
            ),
            const SizedBox(width: 8),
            _CircleButton(
              icon: Icons.refresh,
              onTap: callbacks.onRefresh,
              colors: colors,
              tooltip: '刷新',
            ),
            const SizedBox(width: 8),
            _CircleButton(
              icon: Icons.more_vert,
              onTap: callbacks.onShowMore,
              colors: colors,
              tooltip: '更多',
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 右侧竖排：自动阅读 / 朗读 / 夜间
// ============================================================

class _SideColumn extends StatelessWidget {
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _SideColumn({required this.callbacks, required this.theme});

  @override
  Widget build(BuildContext context) {
    final colors = _ChromeColors(theme);
    final isDark = theme.background.computeLuminance() < 0.5;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CircleButton(
            icon: Icons.auto_awesome_motion_outlined,
            onTap: callbacks.onStartAutoPage,
            colors: colors,
            tooltip: '自动阅读',
          ),
          const SizedBox(height: 14),
          _CircleButton(
            icon: Icons.play_arrow,
            onTap: callbacks.onStartTts,
            colors: colors,
            tooltip: '朗读',
          ),
          const SizedBox(height: 14),
          _CircleButton(
            icon: isDark ? Icons.wb_sunny_outlined : Icons.dark_mode_outlined,
            onTap: callbacks.onToggleTheme,
            colors: colors,
            tooltip: isDark ? '日间' : '夜间',
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 底部章节滑杆 pill
// ============================================================

class _SliderPill extends StatelessWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _SliderPill({
    required this.data,
    required this.callbacks,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _ChromeColors(theme);
    final canPrev = data.chapterIndex > 0;
    final canNext = data.chapterIndex < data.totalChapters - 1;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colors.pill,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          InkWell(
            onTap: canPrev ? callbacks.onPrevChapter : null,
            borderRadius:
                const BorderRadius.horizontal(left: Radius.circular(24)),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                Icons.chevron_left,
                color:
                    canPrev ? colors.icon : colors.icon.withValues(alpha: 0.3),
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: colors.sliderActive,
                thumbColor: colors.sliderActive,
                inactiveTrackColor: colors.sliderInactive,
              ),
              child: Slider(
                value:
                    (data.chapterSliderValue ?? data.chapterIndex.toDouble())
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
          InkWell(
            onTap: canNext ? callbacks.onNextChapter : null,
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(24)),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                Icons.chevron_right,
                color:
                    canNext ? colors.icon : colors.icon.withValues(alpha: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 底部工具 pill：目录 / 字体 / 背景 / 更多（轻阅时光中间的 AI 入口不做）
// ============================================================

class _ToolbarPill extends StatelessWidget {
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _ToolbarPill({required this.callbacks, required this.theme});

  @override
  Widget build(BuildContext context) {
    final colors = _ChromeColors(theme);
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: colors.pill,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ToolbarEntry(
            icon: Icons.menu_book_outlined,
            tooltip: '目录',
            colors: colors,
            onTap: callbacks.onShowChapterList,
          ),
          _ToolbarEntry(
            icon: Icons.text_fields,
            tooltip: '字体',
            colors: colors,
            onTap: callbacks.onShowSettings,
          ),
          _ToolbarEntry(
            icon: Icons.palette_outlined,
            tooltip: '背景',
            colors: colors,
            onTap: callbacks.onShowBackground,
          ),
          _ToolbarEntry(
            icon: Icons.settings_outlined,
            tooltip: '更多',
            colors: colors,
            onTap: callbacks.onShowMoreSettings,
          ),
        ],
      ),
    );
  }
}

class _ToolbarEntry extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final _ChromeColors colors;
  final VoidCallback onTap;

  const _ToolbarEntry({
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          width: 64,
          height: 56,
          child: Icon(icon, size: 22, color: colors.icon),
        ),
      ),
    );
  }
}

// ============================================================
// TTS 模式底部控制卡
// ============================================================

/// TTS 模式底部（三行）：
///
/// ```
/// «  ⏮  ⏸/▶  ⏹  ⏭  »
/// 朗读语速 0.5 ────────  [⏱ 定时]
///      目录        听书设置
/// ```
class _TtsBottomCard extends StatelessWidget {
  final ReaderControllerViewData data;
  final ReaderControllerCallbacks callbacks;
  final ReaderTheme theme;

  const _TtsBottomCard({
    required this.data,
    required this.callbacks,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _ChromeColors(theme);
    final isPaused = data.ttsState == TtsState.paused;
    return Container(
      decoration: BoxDecoration(
        color: colors.pill,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
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
                color: colors.icon,
                onTap: callbacks.onTtsPrevChapter,
              ),
              _TtsIconButton(
                icon: Icons.skip_previous,
                size: 24,
                color: colors.icon,
                onTap: callbacks.onTtsPrevParagraph,
              ),
              _TtsIconButton(
                icon: isPaused ? Icons.play_arrow : Icons.pause,
                size: 30,
                color: colors.icon,
                onTap: isPaused ? callbacks.onResumeTts : callbacks.onPauseTts,
              ),
              _TtsIconButton(
                icon: Icons.stop,
                size: 26,
                color: colors.icon,
                onTap: callbacks.onStopTts,
              ),
              _TtsIconButton(
                icon: Icons.skip_next,
                size: 24,
                color: colors.icon,
                onTap: callbacks.onTtsNextParagraph,
              ),
              _TtsIconButton(
                icon: Icons.keyboard_double_arrow_right,
                size: 22,
                color: colors.icon,
                onTap: callbacks.onTtsNextChapter,
              ),
            ],
          ),
          const SizedBox(height: 2),
          // ---- 第二行：语速 + 定时 ----
          Row(
            children: [
              const SizedBox(width: 10),
              Text(
                '朗读语速 ${data.ttsRate.toStringAsFixed(1)}',
                style: TextStyle(
                    fontSize: 12, color: colors.icon.withValues(alpha: 0.6)),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: colors.sliderActive,
                    thumbColor: colors.sliderActive,
                    inactiveTrackColor: colors.sliderInactive,
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
                    color: colors.icon.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.timer_outlined, size: 14, color: colors.icon),
                      const SizedBox(width: 4),
                      Text('定时',
                          style: TextStyle(fontSize: 12, color: colors.icon)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
          const SizedBox(height: 2),
          // ---- 第三行：目录 / 听书设置 ----
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _TtsTextEntry(
                icon: Icons.menu_book_outlined,
                label: '目录',
                color: colors.icon,
                onTap: callbacks.onShowChapterList,
              ),
              _TtsTextEntry(
                icon: Icons.settings_outlined,
                label: '听书设置',
                color: colors.icon,
                onTap: callbacks.onShowTtsSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 朗读控制卡上的图标按钮
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

/// 朗读控制卡第三行的图文入口
class _TtsTextEntry extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TtsTextEntry({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
