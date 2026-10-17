import 'package:flutter/material.dart';

import '../../models/search_result.dart';
import '../../services/api_service.dart';

/// 发现页书籍列表项 —— 「左书封 + 右元信息 + 简介摘要」横向布局。
///
/// 【为什么单独抽出来】
/// 新发现页直接列出当前分类下的书，每条都是这种横向布局；它和
/// `explore_books_page.dart` 里的网格 item 是同一种数据（SearchResult）。
/// 抽到 widget 后两边都能复用，避免「改了列表样式只改了主页，子页
/// 仍是网格」这种割裂感。
class ExploreBookTile extends StatelessWidget {
  const ExploreBookTile({
    Key? key,
    required this.book,
    required this.sourceName,
    required this.onTap,
    this.coverWidth = 78,
  }) : super(key: key);

  final SearchResult book;
  final String? sourceName;

  /// 点整条触发的回调 —— 调用方通常弹底 sheet（书名/简介/加入书架）。
  final VoidCallback onTap;

  /// 书封宽度。书封是固定 1:1.4 的竖图（接近书脊比例），高度由宽度决定。
  final double coverWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(
              url: book.coverUrl,
              origin: book.origin,
              width: coverWidth,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.name ?? '未命名',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    book.author ?? '未知作者',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _MetaRow(
                    originName: book.originName ?? sourceName,
                    wordCount: book.wordCount,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if ((book.intro ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      book.intro!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书封 —— 用 getCoverProxyUrl 走后端代理，避开书源 refer/防盗链问题。
class _Cover extends StatelessWidget {
  const _Cover({
    required this.url,
    required this.origin,
    required this.width,
  });

  final String? url;
  final String? origin;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 1.4;
    final placeholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.menu_book_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: width * 0.4,
      ),
    );
    if (url == null || url!.isEmpty) return placeholder;
    final proxied = ApiService.instance.getCoverProxyUrl(url, sourceUrl: origin);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        proxied,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return placeholder;
        },
      ),
    );
  }
}

/// 「来源：xxx · xx万字」一行 —— 两个文本各取所需，留空就整段隐藏。
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.originName,
    required this.wordCount,
    required this.style,
  });

  final String? originName;
  final String? wordCount;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (originName != null && originName!.isNotEmpty) parts.add('来源：$originName');
    if (wordCount != null && wordCount!.isNotEmpty) parts.add('$wordCount字');
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join('  '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}
