import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/routes.dart';
import '../models/book.dart';
import '../pages/bookshelf/book_info_page.dart';
import '../services/api_service.dart';
import '../services/app_settings.dart';

enum BookCardDisplayMode {
  compact,
  detailed,
}

class BookCard extends StatelessWidget {
  final Book book;
  final BookCardDisplayMode displayMode;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectionToggle;

  const BookCard({
    Key? key,
    required this.book,
    this.displayMode = BookCardDisplayMode.compact,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionToggle,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final child = displayMode == BookCardDisplayMode.detailed
        ? _buildDetailedCard(context)
        : _buildCompactCard(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        // 对齐官方 3.41：
        //   单击封面 → 直接进阅读器；
        //   长按封面 → 进「书籍信息」页（删除 / 更换书源 / 改分组等都在这页）。
        // 之前两个手势都进信息页，导致「点封面进不去阅读」。
        onTap: selectionMode ? onSelectionToggle : () => _openReader(context),
        onLongPress:
            selectionMode ? onSelectionToggle : () => _openInfo(context),
        child: child,
      ),
    );
  }

  /// 打开书籍信息页
  void _openInfo(BuildContext context) {
    Navigator.pushNamed(
      context,
      AppRoutes.bookInfo,
      arguments: BookInfoPageArgs(book: book),
    );
  }

  Widget _buildCompactCard(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _buildCover(context, radius: 16)),
              if (_unreadCount > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: _UnreadBadge(count: _unreadCount),
                ),
              if (selectionMode)
                Positioned(
                  top: 8,
                  left: 8,
                  child: _SelectionBadge(selected: selected),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          book.name ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }

  Widget _buildDetailedCard(BuildContext context) {
    final theme = Theme.of(context);
    final author = (book.author ?? '').trim();
    final source = (book.originName ?? '').trim();
    final totalChapters = book.totalChapterNum;
    final latestTitle = (book.latestChapterTitle ?? '').trim();
    final readTitle = (book.durChapterTitle ?? '').trim();
    final metaParts = <String>[
      if (author.isNotEmpty) author,
      if (totalChapters != null && totalChapters > 0) '共$totalChapters章',
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.45)
              : theme.dividerColor.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              SizedBox(
                width: 76,
                height: 104,
                child: _buildCover(context, radius: 12),
              ),
              if (selectionMode)
                Positioned(
                  top: 6,
                  left: 6,
                  child: _SelectionBadge(selected: selected),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                if (metaParts.isNotEmpty)
                  Text(
                    metaParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.textTheme.bodyMedium?.color
                          ?.withValues(alpha: 0.72),
                    ),
                  ),
                if (readTitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '已读：$readTitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.textTheme.bodyMedium?.color
                          ?.withValues(alpha: 0.72),
                    ),
                  ),
                ],
                if (source.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '来源：$source',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.textTheme.bodyMedium?.color
                          ?.withValues(alpha: 0.72),
                    ),
                  ),
                ],
                if (latestTitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_formatRelativeTime()}：$latestTitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.textTheme.bodyMedium?.color
                          ?.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_unreadCount > 0) _UnreadBadge(count: _unreadCount),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCover(BuildContext context, {required double radius}) {
    final coverUrl = book.customCoverUrl ?? book.coverUrl;
    final placeholder = Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.menu_book_rounded,
        size: radius * 2.3,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    // 书架菜单「默认封面」：开启后所有卡片都用占位封面。
    // 书源封面经常 403/超时，统一占位反而更整齐。
    if (AppSettings.instance.useDefaultCover) {
      return placeholder;
    }
    if (coverUrl == null || coverUrl.isEmpty) {
      return placeholder;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: ApiService.instance.getCoverProxyUrl(
          coverUrl,
          sourceUrl: book.origin,
        ),
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }

  int get _unreadCount {
    final total = book.totalChapterNum;
    if (total == null || total <= 0) return 0;
    final currentIndex = book.durChapterIndex ?? -1;
    final unread = total - (currentIndex + 1);
    return unread > 0 ? unread : 0;
  }

  String _formatRelativeTime() {
    final raw = book.latestChapterTime ?? book.lastCheckTime;
    if (raw == null || raw <= 0) {
      return '最近更新';
    }

    final millis = raw > 1000000000000 ? raw : raw * 1000;
    final target = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime.now().difference(target);

    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    return '${target.month}月${target.day}日';
  }

  void _openReader(BuildContext context) {
    Navigator.pushNamed(context, '/reader', arguments: book);
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 44, minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFFFF5A4D),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SelectionBadge extends StatelessWidget {
  final bool selected;

  const _SelectionBadge({required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primary
            : Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.92), width: 1.5),
      ),
      child: Icon(
        selected ? Icons.check_rounded : Icons.circle_outlined,
        size: 16,
        color: Colors.white,
      ),
    );
  }
}
