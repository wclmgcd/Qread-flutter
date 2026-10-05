import 'package:flutter/material.dart';

import '../engine/models.dart';
import 'reader_theme.dart';

/// 阅读页面内容渲染器
///
/// 负责将 PageSlice 渲染为可显示的 Widget，
/// 包括章节头、文本行、段评气泡、页脚等。
///
/// 关键：分页引擎已经精确计算了每页的行数（以及段评气泡占的高度），
/// 渲染端必须严格适配，不能超出可用区域。

/// 段评气泡
///
/// 外观参考正版客户端：一个圆角小方块 + 左下角小尾巴，中间是评论条数。
class CommentBubble extends StatelessWidget {
  final ParagraphComment comment;
  final ReaderTheme theme;
  final VoidCallback? onTap;

  const CommentBubble({
    Key? key,
    required this.comment,
    required this.theme,
    this.onTap,
  }) : super(key: key);

  static const double _boxWidth = 36;
  static const double _tailHeight = 5;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 高度必须与分页引擎的 kCommentBubbleTotalHeight 一致
      height: kCommentBubbleTotalHeight,
      child: Padding(
        padding: const EdgeInsets.only(top: kCommentBubbleTopSpacing),
        child: Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox(
              width: _boxWidth,
              height: kCommentBubbleHeight,
              child: CustomPaint(
                painter: _BubblePainter(
                  color: theme.secondaryText,
                ),
                child: Padding(
                  padding: EdgeInsets.only(bottom: _tailHeight),
                  child: Center(
                    child: Text(
                      comment.count,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.1,
                        color: theme.secondaryText,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BubblePainter extends CustomPainter {
  final Color color;

  _BubblePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = color.withValues(alpha: 0.75);

    const tailHeight = CommentBubble._tailHeight;
    final bodyHeight = size.height - tailHeight;

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.4, 0.4, size.width - 0.8, bodyHeight - 0.8),
      const Radius.circular(5),
    );
    canvas.drawRRect(body, stroke);

    // 左下角小尾巴
    final tail = Path()
      ..moveTo(8, bodyHeight - 0.4)
      ..lineTo(9, size.height - 0.6)
      ..lineTo(14, bodyHeight - 0.4);
    canvas.drawPath(tail, stroke);
  }

  @override
  bool shouldRepaint(_BubblePainter oldDelegate) => oldDelegate.color != color;
}

class ContentRenderer {
  /// 渲染一个完整页面
  static Widget buildPage({
    required PageSlice page,
    required ReaderTheme theme,
    required double fontSize,
    required double lineHeight,
    required String chapterTitle,
    required String pageIndicator,
    required String timeLabel,
    required String batteryLabel,
    required int ttsParagraphIndex,
    bool showTopBar = true,
    bool showBottomBar = true,
    bool showPageNumber = true,
    double horizontalPadding = 24.0,
    double topPadding = 18.0,
    double paragraphSpacing = 10.0,
    double firstLineIndent = 2.0,
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
    ValueChanged<ParagraphComment>? onCommentTap,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, topPadding,
          horizontalPadding, showBottomBar ? 10.0 : 0.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTopBar) _buildChapterHeader(chapterTitle, theme, fontFamily),
          if (showTopBar) const SizedBox(height: 14),
          // 使用 Expanded 限制文字区域高度，内部用 ClipRect 裁剪
          Expanded(
            child: ClipRect(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in page.lines) ...[
                      _buildTextLine(
                        line: line,
                        theme: theme,
                        fontSize: fontSize,
                        lineHeight: lineHeight,
                        ttsParagraphIndex: ttsParagraphIndex,
                        paragraphSpacing: paragraphSpacing,
                        firstLineIndent: firstLineIndent,
                        fontFamily: fontFamily,
                        fontWeight: fontWeight,
                      ),
                      for (final comment in line.comments)
                        CommentBubble(
                          comment: comment,
                          theme: theme,
                          onTap: onCommentTap == null
                              ? null
                              : () => onCommentTap(comment),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // 页脚固定在底部
          if (showBottomBar)
            _buildFooter(
              theme: theme,
              pageIndicator: showPageNumber ? pageIndicator : '',
              timeLabel: timeLabel,
              batteryLabel: batteryLabel,
              fontFamily: fontFamily,
            ),
        ],
      ),
    );
  }

  /// 渲染章节头
  static Widget _buildChapterHeader(
      String title, ReaderTheme theme, String? fontFamily) {
    if (title.isEmpty) return const SizedBox.shrink();
    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        height: 1.2,
        color: theme.secondaryText,
        fontFamily: fontFamily,
      ),
    );
  }

  /// 渲染单行文本
  static Widget _buildTextLine({
    required TextLine line,
    required ReaderTheme theme,
    required double fontSize,
    required double lineHeight,
    required int ttsParagraphIndex,
    double paragraphSpacing = 10.0,
    double firstLineIndent = 2.0,
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
  }) {
    final isHighlighted = line.paragraphIndex == ttsParagraphIndex;
    final isTitle = line.isTitle;
    final effectiveFontSize = isTitle ? fontSize + 4 : fontSize;
    final effectiveLineHeight = isTitle ? 1.45 : lineHeight;
    final effectiveWeight = isTitle ? FontWeight.w600 : fontWeight;
    final effectiveColor = isHighlighted ? theme.highlight : theme.text;

    // 首行缩进
    final indentChars = isTitle ? 0 : firstLineIndent.round();
    final indentStr =
        line.isFirstLineOfParagraph ? '\u3000' * indentChars : '';
    final displayText = isTitle ? line.text : '$indentStr${line.text}';

    // 段落间距：段尾行用 paragraphSpacing，段内行 2px
    final marginBottom = line.isLastLineOfParagraph ? paragraphSpacing : 2.0;

    return Container(
      margin: EdgeInsets.only(bottom: marginBottom),
      child: Text(
        displayText,
        style: TextStyle(
          fontSize: effectiveFontSize,
          color: effectiveColor,
          height: effectiveLineHeight,
          fontWeight: effectiveWeight,
          fontFamily: fontFamily,
        ),
      ),
    );
  }

  /// 渲染滚动模式的段落
  static Widget buildParagraph({
    required ReaderParagraph paragraph,
    required ReaderTheme theme,
    required double fontSize,
    required double lineHeight,
    required int ttsParagraphIndex,
    double paragraphSpacing = 10.0,
    double firstLineIndent = 2.0,
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
    ValueChanged<ParagraphComment>? onCommentTap,
  }) {
    final isHighlighted = paragraph.index == ttsParagraphIndex;
    final isTitle = paragraph.isTitle;
    final effectiveFontSize = isTitle ? fontSize + 4 : fontSize;
    final effectiveLineHeight = isTitle ? 1.45 : lineHeight;
    final effectiveWeight = isTitle ? FontWeight.w600 : fontWeight;

    // 首行缩进 / 段间距改为跟随阅读设置
    final indentChars = isTitle ? 0 : firstLineIndent.round();
    final indentStr = '\u3000' * indentChars;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: EdgeInsets.only(bottom: paragraphSpacing),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            color: isHighlighted ? theme.highlight : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            isTitle ? paragraph.text : '$indentStr${paragraph.text}',
            style: TextStyle(
              fontSize: effectiveFontSize,
              color: theme.text,
              height: effectiveLineHeight,
              fontWeight: effectiveWeight,
              fontFamily: fontFamily,
            ),
          ),
        ),
        for (final comment in paragraph.comments)
          CommentBubble(
            comment: comment,
            theme: theme,
            onTap:
                onCommentTap == null ? null : () => onCommentTap(comment),
          ),
      ],
    );
  }

  /// 渲染页脚
  static Widget _buildFooter({
    required ReaderTheme theme,
    required String pageIndicator,
    required String timeLabel,
    required String batteryLabel,
    String? fontFamily,
  }) {
    final style = TextStyle(
      fontSize: 11,
      height: 1.2,
      color: theme.secondaryText,
      fontFamily: fontFamily,
    );
    return Row(
      children: [
        Text(timeLabel, style: style),
        const Spacer(),
        Text(pageIndicator, style: style),
        const Spacer(),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.battery_std, size: 13, color: theme.secondaryText),
            const SizedBox(width: 4),
            Text(batteryLabel, style: style),
          ],
        ),
      ],
    );
  }
}
