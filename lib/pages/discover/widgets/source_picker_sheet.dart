import 'package:flutter/material.dart';

import '../../../models/book_source.dart';

/// 书源选择底 sheet —— 发现页顶部那颗「书源胶囊」点开后弹出它。
///
/// 用法：
/// ```dart
/// final picked = await showSourcePickerSheet(
///   context,
///   sources: provider.exploreSources,
///   currentUrl: provider.currentSourceUrl,
/// );
/// ```
/// 返回用户选中的书源；直接关掉返回 null。
///
/// 【为什么用 modal sheet 而不是下拉菜单】
/// 书源动辄几十上百个，PopupMenu 一屏放不下也不能搜索。原版也是这样：
/// 一个可拖拽的底 sheet，顶部搜索、右上角 AZ 排序与筛选。
Future<BookSource?> showSourcePickerSheet(
  BuildContext context, {
  required List<BookSource> sources,
  required String? currentUrl,
}) {
  return showModalBottomSheet<BookSource>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _SourcePickerSheet(
      sources: sources,
      currentUrl: currentUrl,
    ),
  );
}

class _SourcePickerSheet extends StatefulWidget {
  const _SourcePickerSheet({
    required this.sources,
    required this.currentUrl,
  });

  final List<BookSource> sources;
  final String? currentUrl;

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  final TextEditingController _search = TextEditingController();
  bool _sortAZ = false;
  /// 只看「有发现页」的源？默认全看 —— 能进这个列表的本来就都是
  /// `enabledExplore == true` 的，这个开关是给「分组筛选」留的扩展位。
  bool _filterEnabledOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<BookSource> get _visible {
    final q = _search.text.trim().toLowerCase();
    var list = widget.sources.where((s) {
      if (_filterEnabledOnly && s.enabled != true) return false;
      if (q.isEmpty) return true;
      final name = (s.bookSourceName ?? '').toLowerCase();
      final group = (s.bookSourceGroup ?? '').toLowerCase();
      final url = (s.bookSourceUrl ?? '').toLowerCase();
      return name.contains(q) || group.contains(q) || url.contains(q);
    }).toList();

    if (_sortAZ) {
      list.sort((a, b) => (a.bookSourceName ?? '')
          .toLowerCase()
          .compareTo((b.bookSourceName ?? '').toLowerCase()));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _visible;
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(21),
                    ),
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: '搜索书源',
                        prefixIcon: Icon(Icons.search, size: 20),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _RoundIconButton(
                  tooltip: '按名称排序',
                  active: _sortAZ,
                  icon: Icons.sort_by_alpha,
                  onPressed: () => setState(() => _sortAZ = !_sortAZ),
                ),
                _RoundIconButton(
                  tooltip: '只看已启用',
                  active: _filterEnabledOnly,
                  icon: Icons.filter_alt_outlined,
                  onPressed: () =>
                      setState(() => _filterEnabledOnly = !_filterEnabledOnly),
                ),
                _RoundIconButton(
                  tooltip: '关闭',
                  icon: Icons.close,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      '没有匹配的书源',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: controller,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final source = list[index];
                      return _SourceRow(
                        source: source,
                        selected:
                            source.bookSourceUrl == widget.currentUrl,
                        onTap: () => Navigator.pop(context, source),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final BookSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = (source.bookSourceName ?? '').trim();
    final group = (source.bookSourceGroup ?? '').trim();
    final accent = sourceAccentColor(name.isNotEmpty ? name : group);

    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(
          name.isNotEmpty ? name.characters.first : '源',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: group.isEmpty
          ? null
          : Text(
              group,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: selected
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : null,
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: 20,
        color: active ? theme.colorScheme.primary : null,
      ),
      style: IconButton.styleFrom(
        backgroundColor: active
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 按书源名生成一个稳定的强调色。
///
/// 【为什么不用随机色】同一个书源每次进来颜色必须一样，否则用户刚记住
/// 「红圈那个是知秋」，下次刷新变成蓝的，就没法靠颜色认源了。
/// 用名字字符和取模保证稳定。
Color sourceAccentColor(String seed) {
  const palette = [
    Color(0xFFE85D3F),
    Color(0xFF4B8BFF),
    Color(0xFF35A97A),
    Color(0xFFF0A53A),
    Color(0xFF8B63F6),
    Color(0xFFE05C92),
  ];
  if (seed.isEmpty) return palette.first;
  var sum = 0;
  for (final unit in seed.codeUnits) {
    sum = (sum + unit) % 100000;
  }
  return palette[sum % palette.length];
}
