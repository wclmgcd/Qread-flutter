import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../engine/pagination_engine.dart';
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

  /// 页脚（时间/页码/电量）底部的额外留白，原来这里硬编码 10。
  /// 滚动模式同样不再由外层安全区兜底，得自己避开系统手势条，
  /// 所以改由阅读页按 PaginationEngine.footerBottomPadding 算好传进来。
  final double bottomPadding;
  final double paragraphSpacing;
  final double firstLineIndent;
  final String? fontFamily;
  final FontWeight fontWeight;
  final ValueChanged<ParagraphComment>? onCommentTap;

  /// 正文大标题对齐（更多设置「标题对齐」），分页/滚动共用。
  final TextAlign titleAlign;

  /// 页眉/页脚与正文之间的细分隔线。
  final bool showHeaderFooterDivider;

  /// 页脚左侧时间 / 右侧电量。
  final bool showFooterTime;
  final bool showFooterBattery;

  /// 正文插图的地址构造器（原始 src → 可加载的完整 URL），由阅读页注入。
  /// 见 PagedReader.imageUrlBuilder 的同款说明。
  final String Function(String src)? imageUrlBuilder;

  /// 点正文插图时的回调，参数是拼好的最终地址（由阅读页注入去开大图）。
  final ValueChanged<String>? onImageTap;

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
    this.bottomPadding = PaginationEngine.defaultBottomPadding,
    this.paragraphSpacing = 7.0,
    this.firstLineIndent = 2.0,
    this.fontFamily,
    this.fontWeight = FontWeight.normal,
    this.onCommentTap,
    this.titleAlign = TextAlign.center,
    this.showHeaderFooterDivider = false,
    this.showFooterTime = true,
    this.showFooterBattery = true,
    this.imageUrlBuilder,
    this.onImageTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (paragraphs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
          horizontalPadding, topPadding, horizontalPadding, bottomPadding),
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
          // 与分页模式同款：分割线嵌在原有 6px 间距里（1px 线 + 5px 距）
          if (showHeaderFooterDivider) ...[
            Divider(height: 1, thickness: 1, color: theme.divider),
            const SizedBox(height: 5),
          ] else
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
                  titleAlign: titleAlign,
                  imageUrlBuilder: imageUrlBuilder,
                  onImageTap: onImageTap,
                );
              },
            ),
          ),
          // 页脚分割线（1px 线 + 5px 距），与分页模式同一观感
          if (showHeaderFooterDivider) ...[
            const SizedBox(height: 5),
            Divider(height: 1, thickness: 1, color: theme.divider),
          ] else
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
        if (showFooterTime) Text(timeLabel, style: style),
        const Spacer(),
        Text(pageIndicator, style: style),
        const Spacer(),
        if (showFooterBattery)
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
