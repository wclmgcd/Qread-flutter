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
    // 系统字号放大时，书名两行的高度要跟着放大，否则文字会被裁
    final titleScaler = MediaQuery.textScalerOf(context).scale(1.0);
    // 角标宽度固定为封面的 1/4。
    //
    // 【为什么不能用「按内容自适应 + minWidth」】原来给的是
    // `BoxConstraints(minWidth: 44)`，于是「6」和「99+」都是 44dp 宽 ——
    // 在 3 列网格里封面才 ~99dp，角标吃掉 44% 的宽度，看起来像在啃封面。
    // 用 LayoutBuilder 拿到卡片（=封面）宽度，取 1/4 作为固定宽度，
    // 不管内容是一个数字还是「99+」，占位都一样。
    return LayoutBuilder(
      builder: (context, constraints) {
        final badgeWidth = constraints.maxWidth / 4;
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
                      child: _UnreadBadge(
                        count: _unreadCount,
                        width: badgeWidth,
                      ),
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
            // 【封面大小不一致的原因】书名原来直接跟在封面下面，1 行书名占 1 行、
            // 2 行书名占 2 行，而上面的封面是 Expanded —— 书名多占一行，封面就被
            // 压缩一行，于是同一屏里封面高矮不一。这里把书名区域**固定成两行高**，
            // 封面高度就恒定了。
            SizedBox(
              height: 38 * titleScaler,
              child: Text(
                book.name ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
              ),
            ),
          ],
        );
      },
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

  /// 固定宽度（书架网格里传封面宽度的 1/4）。
  ///
  /// 为 null 时退化成「按内容自适应 + 最小 44」——详细列表模式下角标排在
  /// 卡片右侧，不压在封面上，没有「啃封面」的问题，保持原样即可。
  final double? width;

  const _UnreadBadge({required this.count, this.width});

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    final w = width;
    final fixed = w != null;
    return Container(
      width: w,
      // 高度按宽度的 0.62 走，和封面保持同一比例
      height: fixed ? w * 0.62 : null,
      constraints: fixed ? null : const BoxConstraints(minWidth: 44, minHeight: 32),
      padding: fixed
          ? const EdgeInsets.symmetric(horizontal: 3, vertical: 1)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFFFF5A4D),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
        ),
      ),
      alignment: Alignment.center,
      // 字号跟着角标宽度走；FittedBox 兜底，避免「99+」在小角标里溢出
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: fixed ? w * 0.42 : 14,
            fontWeight: FontWeight.w700,
          ),
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
