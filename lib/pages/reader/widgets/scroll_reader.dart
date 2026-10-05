import 'package:flutter/material.dart';

import '../engine/models.dart';
import 'content_renderer.dart';
import 'reader_theme.dart';

/// 滚动模式阅读器

class ScrollReader extends StatelessWidget {
  final List<ReaderParagraph> paragraphs;
  final ScrollController scrollController;
  final ReaderTheme theme;
  final double fontSize;
  final double lineHeight;
  final String chapterTitle;
  final int ttsParagraphIndex;
  final String pageIndicator;
  final String timeLabel;
  final String batteryLabel;

  /// 以下四项原先写死在 build 里 (24/18/10/2), 导致"左右边距""上方边距"
  /// "段间距""首行空格"四个滑块在滚动模式下完全没反应。
  final double horizontalPadding;
  final double topPadding;
  final double paragraphSpacing;
  final double firstLineIndent;
  final String? fontFamily;
  final FontWeight fontWeight;
  final ValueChanged<ParagraphComment>? onCommentTap;

  const ScrollReader({
    Key? key,
    required this.paragraphs,
    required this.scrollController,
    required this.theme,
    required this.fontSize,
    required this.lineHeight,
    required this.chapterTitle,
    this.ttsParagraphIndex = -1,
    required this.pageIndicator,
    required this.timeLabel,
    required this.batteryLabel,
    this.horizontalPadding = 16.0,
    this.topPadding = 10.0,
    this.paragraphSpacing = 7.0,
    this.firstLineIndent = 2.0,
    this.fontFamily,
    this.fontWeight = FontWeight.normal,
    this.onCommentTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (paragraphs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, topPadding,
          horizontalPadding, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 章节标题用和分页模式同一套样式（小字、与正文同色），
          // 不要再走 buildParagraph —— 那会用「正文+4、加粗」画成一大行，
          // 和分页模式对不上。
          ContentRenderer.buildChapterHeader(
            chapterTitle,
            theme,
            fontFamily,
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: EdgeInsets.zero,
              itemCount: paragraphs.length,
              itemBuilder: (context, index) {
                return ContentRenderer.buildParagraph(
                  paragraph: paragraphs[index],
                  theme: theme,
                  fontSize: fontSize,
                  lineHeight: lineHeight,
                  ttsParagraphIndex: ttsParagraphIndex,
                  paragraphSpacing: paragraphSpacing,
                  firstLineIndent: firstLineIndent,
                  fontFamily: fontFamily,
                  fontWeight: fontWeight,
                  onCommentTap: onCommentTap,
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final style = TextStyle(
      fontSize: 11,
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
