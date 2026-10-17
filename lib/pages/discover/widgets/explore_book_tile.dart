import 'package:flutter/material.dart';

// 【为什么是三层 ../】本文件在 lib/pages/discover/widgets/ 下，
// 回 lib/ 要经过 widgets → discover → pages 三层。
// 两层会解析成 lib/pages/models/... （不存在），CI 上直接报 uri_does_not_exist。
import '../../../models/search_result.dart';
import '../../../services/api_service.dart';

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
                    kind: book.kind,
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

/// 元信息两行：第一行「来源：xxx」，第二行「20.4万字 连载,玄幻,东方玄幻」。
///
/// 【为什么是两行而不是一行挤在一起】参考图上来源单独一行（前面还有书源图标），
/// 字数与连载状态/分类在下一行。挤成一行的话窄屏上必然先截掉分类 —— 而分类
/// 恰恰是用户在发现页用来判断"这本合不合口味"的信息，优先于来源。
///
/// 【为什么 kind 要拆开再拼】书源的 kind 规则五花八门：知秋终版写的是
/// `{{$.status}}\n{{$.category}}\n{{$.subCategory}}\n`（换行分隔且**带尾换行**），
/// 也有源用逗号分隔。直接显示会带出空行。这里统一按逗号/顿号/换行切开、
/// 丢掉空项、再用逗号拼回去，两种写法都能得到「连载,玄幻,东方玄幻」。
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.originName,
    required this.wordCount,
    required this.kind,
    required this.style,
  });

  final String? originName;
  final String? wordCount;
  final String? kind;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];
    if (originName != null && originName!.isNotEmpty) {
      lines.add('来源：$originName');
    }

    final stats = <String>[];
    final wc = _formatWordCount(wordCount);
    if (wc.isNotEmpty) stats.add(wc);
    final kinds = (kind ?? '')
        .split(RegExp(r'[,，、\n\r]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (kinds.isNotEmpty) stats.add(kinds.join(','));
    if (stats.isNotEmpty) lines.add(stats.join('  '));

    if (lines.isEmpty) return const SizedBox.shrink();
    return Text(
      lines.join('\n'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: style?.copyWith(height: 1.5),
    );
  }
}

/// 字数归一化。
///
/// 【为什么不能直接拼个「字」字】书源的 wordCount 规则（知秋终版写的是
/// `wordsCount`）拿到的可能是**已经带单位**的 `20.4万字`，也可能是裸数字
/// `204000`。原来的实现无条件拼「字」，前一种就成了「20.4万字字」。
/// 这里只对"通篇是数字"的形态做换算，其余原样透传 —— 拿不准的时候不要动它，
/// 猜错了会把 `12 万字` 这种带空格的写法也搞坏。
String _formatWordCount(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return '';
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return s;
  final n = double.tryParse(s);
  if (n == null) return s;
  if (n >= 10000) {
    final w = n / 10000;
    // 20.4万 / 20万 —— 整除时不留 ".0"
    final text = w == w.roundToDouble()
        ? w.round().toString()
        : w.toStringAsFixed(1);
    return '$text万字';
  }
  return '${n.round()}字';
}
