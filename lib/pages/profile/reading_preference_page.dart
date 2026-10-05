import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/routes.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/app_settings.dart';
import '../../services/storage_service.dart';

/// 阅读偏好
///
/// 对齐官方 3.41「我的 → 阅读偏好」：
/// 书架设置 / 主题设置 / 阅读设置 / 听书设置 / 替换净化 / 其他设置。
/// 本仓库以前没有这个页面，阅读相关开关全塞在阅读器底部弹窗里，
/// 书架排序、简繁转换、段评样式等设置项则完全不存在。
class ReadingPreferencePage extends StatefulWidget {
  const ReadingPreferencePage({Key? key}) : super(key: key);

  @override
  State<ReadingPreferencePage> createState() => _ReadingPreferencePageState();
}

class _ReadingPreferencePageState extends State<ReadingPreferencePage> {
  int _chapterCacheCount = 5;

  @override
  void initState() {
    super.initState();
    _loadCacheCount();
  }

  Future<void> _loadCacheCount() async {
    final storage = await StorageService.instance;
    final v = storage.readerChapterCacheCount;
    if (mounted) setState(() => _chapterCacheCount = v);
  }

  AppSettings get _s => context.watch<AppSettings>();

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读偏好'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _section('书架设置'),
          _navRow(
            icon: Icons.sort,
            title: '书架排序',
            value: s.bookshelfSort.label,
            onTap: _pickBookshelfSort,
          ),

          _section('主题设置'),
          _navRow(
            icon: Icons.dark_mode_outlined,
            title: '夜间模式',
            value: s.nightMode.label,
            onTap: _pickNightMode,
          ),

          _section('阅读设置'),
          _navRow(
            icon: Icons.translate,
            title: '简繁转换',
            value: s.chineseConvert.label,
            onTap: _pickChineseConvert,
          ),
          _navRow(
            icon: Icons.download_outlined,
            title: '缓存章数',
            value: '预缓存 $_chapterCacheCount 章',
            onTap: _pickCacheCount,
          ),
          _navRow(
            icon: Icons.record_voice_over_outlined,
            title: '朗读缓存',
            value: '${s.ttsCacheCount}',
            onTap: _pickTtsCacheCount,
          ),
          _navRow(
            icon: Icons.chat_bubble_outline,
            title: '段评样式',
            value: s.commentStyle.label,
            onTap: _pickCommentStyle,
          ),
          _navRow(
            icon: Icons.auto_stories_outlined,
            title: '翻页设置',
            value: s.pageAnimTypeLabel,
            onTap: _pickPageAnim,
          ),
          _navRow(
            icon: Icons.image_outlined,
            title: '图片限制',
            value: '最大下载 ${s.imageLimit} 张',
            onTap: _pickImageLimit,
          ),
          _switchRow(
            icon: Icons.cleaning_services_outlined,
            title: '替换净化',
            subtitle: '阅读时应用「替换净化」规则',
            value: s.useReplaceRule,
            onChanged: s.setUseReplaceRule,
          ),

          _section('听书设置'),
          _switchRow(
            icon: Icons.headphones_outlined,
            title: '后台播放',
            subtitle: '退到后台继续朗读',
            value: s.ttsBackground,
            onChanged: s.setTtsBackground,
          ),

          _section('替换净化'),
          _switchRow(
            icon: Icons.save_outlined,
            title: '本地储存',
            subtitle: '净化后的正文存到本地',
            value: s.replaceLocalStorage,
            onChanged: s.setReplaceLocalStorage,
          ),
          _navRow(
            icon: Icons.rule,
            title: '净化规则管理',
            onTap: () =>
                Navigator.pushNamed(context, AppRoutes.replaceRules),
          ),

          _section('其他设置'),
          _navRow(
            icon: Icons.dns_outlined,
            title: '搜索线程',
            value: '${s.searchThreadCount}线程',
            onTap: _pickSearchThread,
          ),
          _switchRow(
            icon: Icons.wifi_tethering,
            title: '通讯长连',
            subtitle: '保持 WebSocket 连接（段评/登录页推送）',
            value: s.webSocketEnabled,
            onChanged: s.setWebSocketEnabled,
          ),
          _switchRow(
            icon: Icons.rss_feed,
            title: '显示订阅',
            subtitle: '底部导航显示「订阅」',
            value: s.showSubscribe,
            onChanged: s.setShowSubscribe,
          ),
          _switchRow(
            icon: Icons.explore_outlined,
            title: '显示发现',
            subtitle: '底部导航显示「发现」',
            value: s.showDiscover,
            onChanged: s.setShowDiscover,
          ),
          _switchRow(
            icon: Icons.splitscreen_outlined,
            title: '多屏设置',
            value: s.multiScreen,
            onChanged: s.setMultiScreen,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 布局

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
          ),
        ),
      );

  Widget _navRow({
    required IconData icon,
    required String title,
    String? value,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, size: 22, color: Colors.grey.shade700),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Text(
              value,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon, size: 22, color: Colors.grey.shade700),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
      value: value,
      onChanged: (v) => onChanged(v),
    );
  }

  // ---------------------------------------------------------------- 选择器

  Future<void> _pickBookshelfSort() async {
    final s = _s;
    final picked = await _pickSimple<BookshelfSort>(
      title: '书架排序',
      entries: {
        for (final v in BookshelfSort.values) v: v.label,
      },
      current: s.bookshelfSort,
    );
    if (picked == null) return;
    await s.setBookshelfSort(picked);
    if (!mounted) return;
    // 排完立刻重排书架，不用等下次刷新
    context.read<BookshelfProvider>().applySort();
    _toast('书架排序：${picked.label}');
  }

  Future<void> _pickNightMode() async {
    final s = _s;
    final picked = await _pickSimple<NightMode>(
      title: '夜间模式',
      entries: {
        for (final v in NightMode.values) v: v.label,
      },
      current: s.nightMode,
    );
    if (picked == null) return;
    await s.setNightMode(picked);
    if (!mounted) return;
    await context.read<ThemeProvider>().setThemeMode(picked.themeMode);
  }

  Future<void> _pickChineseConvert() async {
    final s = _s;
    final picked = await _pickSimple<ChineseConvert>(
      title: '简繁转换',
      entries: {
        for (final v in ChineseConvert.values) v: v.label,
      },
      current: s.chineseConvert,
    );
    if (picked == null) return;
    await s.setChineseConvert(picked);
  }

  Future<void> _pickCommentStyle() async {
    final s = _s;
    final picked = await _pickSimple<CommentBubbleStyle>(
      title: '段评样式',
      entries: {
        for (final v in CommentBubbleStyle.values) v: v.label,
      },
      current: s.commentStyle,
    );
    if (picked == null) return;
    await s.setCommentStyle(picked);
  }

  Future<void> _pickPageAnim() async {
    final s = _s;
    final entries = <String, String>{...AppSettings.pageAnimTypes};
    final picked = await _pickSimple<String>(
      title: '翻页设置',
      entries: entries,
      current: s.pageAnimType,
    );
    if (picked == null) return;
    await s.setPageAnimType(picked);
    _toast('翻页方式：${AppSettings.pageAnimTypes[picked]}');
  }

  Future<void> _pickCacheCount() async {
    final picked = await _pickSimple<int>(
      title: '缓存章数',
      entries: const {3: '3 章', 5: '5 章', 8: '8 章', 10: '10 章', 20: '20 章'},
      current: _chapterCacheCount,
    );
    if (picked == null) return;
    final storage = await StorageService.instance;
    await storage.setReaderChapterCacheCount(picked);
    if (mounted) setState(() => _chapterCacheCount = picked);
  }

  Future<void> _pickTtsCacheCount() async {
    final s = _s;
    final picked = await _pickSimple<int>(
      title: '朗读缓存',
      entries: const {0: '不缓存', 3: '3', 5: '5', 10: '10', 20: '20'},
      current: s.ttsCacheCount,
    );
    if (picked == null) return;
    await s.setTtsCacheCount(picked);
  }

  Future<void> _pickImageLimit() async {
    final s = _s;
    final picked = await _pickSimple<int>(
      title: '图片限制',
      entries: const {
        0: '最大下载 0 张',
        3: '最大下载 3 张',
        5: '最大下载 5 张',
        10: '最大下载 10 张',
        -1: '不限制',
      },
      current: s.imageLimit,
    );
    if (picked == null) return;
    await s.setImageLimit(picked);
  }

  Future<void> _pickSearchThread() async {
    final s = _s;
    final picked = await _pickSimple<int>(
      title: '搜索线程',
      entries: const {1: '1线程', 2: '2线程', 4: '4线程', 6: '6线程', 8: '8线程'},
      current: s.searchThreadCount,
    );
    if (picked == null) return;
    await s.setSearchThreadCount(picked);
  }

  Future<T?> _pickSimple<T>({
    required String title,
    required Map<T, String> entries,
    required T current,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in entries.entries)
                    ListTile(
                      title: Text(e.value),
                      trailing: e.key == current
                          ? const Icon(Icons.check, color: Color(0xFFE05B57))
                          : null,
                      onTap: () => Navigator.pop(ctx, e.key),
                    ),
                ],
              ),
            ),
          ],
        ),
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
}
