import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/rss_manage_provider.dart';
import '../../providers/source_manage_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/file_open_service.dart';

/// 从外部打开 / 分享进来的 JSON 文件，问用户「当成什么导入」。
///
/// 【为什么单独一个页面而不是 showDialog】
/// 这个页面是被 [FileOpenService] 的**广播**触发的，触发点可能在任何时刻、
/// 任何路由之上（甚至 App 刚从冷启动进来、Navigator 还没铺好）。
/// 用 `showDialog` 需要一个「位于 Navigator 之下」的 context，
/// 而冷启动那一刻能拿到的只有全局 `navigatorKey`（在 Navigator 之上），
/// `Navigator.of` 会直接失败。改成往 Navigator 上 push 一个不透明层，
/// 就完全不依赖 context，任何时刻都安全。
class FileImportPage extends StatefulWidget {
  const FileImportPage({Key? key, required this.file}) : super(key: key);

  final OpenedFile file;

  @override
  State<FileImportPage> createState() => _FileImportPageState();
}

/// 这份 JSON 更像书源还是订阅源。
enum _ImportKind { bookSource, rssSource }

/// 一个可点选的「导入为 …」选项行（替代已废弃的 RadioListTile）。
class _KindOption extends StatelessWidget {
  const _KindOption({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyMedium),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileImportPageState extends State<FileImportPage> {
  late _ImportKind _kind;
  late final int _count;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _kind = _detectKind(widget.file.content);
    _count = _countEntries(widget.file.content);
  }

  /// 靠**特征字段**判断，而不是靠文件名。
  ///
  /// 书源必有 `bookSourceUrl`，订阅源必有 `sourceUrl`（legado 的 `RssSource`
  /// 就是这两个键）。用户从聊天软件下载的文件名常常是 `1.json`、`书源(1).json`
  /// 之类，靠名字判会经常判错。
  static _ImportKind _detectKind(String raw) {
    final first = _firstEntry(raw);
    if (first == null) return _ImportKind.bookSource;
    if (first.containsKey('bookSourceUrl')) return _ImportKind.bookSource;
    if (first.containsKey('sourceUrl')) return _ImportKind.rssSource;
    return _ImportKind.bookSource;
  }

  static int _countEntries(String raw) {
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is List) return decoded.length;
      if (decoded is Map) return 1;
    } catch (_) {}
    return 0;
  }

  static Map<String, dynamic>? _firstEntry(String raw) {
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        return Map<String, dynamic>.from(decoded.first as Map);
      }
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  Future<void> _doImport() async {
    final token = context.read<UserProvider>().token ?? '';
    if (token.isEmpty) {
      _toast('请先登录再导入');
      return;
    }

    setState(() => _importing = true);
    String? message;
    try {
      if (_kind == _ImportKind.bookSource) {
        message = await context
            .read<SourceManageProvider>()
            .importSources(token, widget.file.content);
      } else {
        message = await context
            .read<RssManageProvider>()
            .importSources(token, widget.file.content);
      }
    } catch (e) {
      message = '导入失败：$e';
    }
    if (!mounted) return;
    setState(() => _importing = false);

    final label = _kind == _ImportKind.bookSource ? '书源' : '订阅源';
    if (message == null) {
      _toast('导入$label失败，请稍后重试');
      return;
    }
    _toast('已导入$label：$message');
    Navigator.of(context).pop(true);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.45),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('导入文件', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Text(
                      widget.file.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _count > 0 ? '共 $_count 条' : '内容不是合法的 JSON',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '导入为',
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    // 自动判出来的那一项默认选中，但允许用户改 ——
                    // 万一书源里恰好也带了 sourceUrl 字段，判断会偏，
                    // 给用户一个纠正的机会。
                    //
                    // 【为什么不用 RadioListTile】
                    // Flutter 3.32 起 `RadioListTile.groupValue` / `onChanged`
                    // 被 RadioGroup 取代、标成 deprecated。本工程 CI 用的是
                    // Flutter 3.41.9，`flutter analyze` 会把
                    // `deprecated_member_use` 当 warning 报出来（warning 默认
                    // 是 fatal 的），直接就是 CI 红。这里自绘一个选项行，
                    // 只用一个 check 图标，反而更短。
                    _KindOption(
                      selected: _kind == _ImportKind.bookSource,
                      title: '书源',
                      subtitle: '导入到「书源管理」',
                      onTap: _importing
                          ? null
                          : () => setState(
                              () => _kind = _ImportKind.bookSource),
                    ),
                    _KindOption(
                      selected: _kind == _ImportKind.rssSource,
                      title: '订阅源',
                      subtitle: '导入到「订阅源管理」',
                      onTap: _importing
                          ? null
                          : () => setState(() => _kind = _ImportKind.rssSource),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _importing
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _importing ? null : _doImport,
                          child: _importing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('导入'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
