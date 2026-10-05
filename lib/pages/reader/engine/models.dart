/// 阅读器分页引擎数据模型
///
/// 层级结构：ChapterLayout → PageSlice → TextLine
/// 与旧版 Block 模型不同，新版采用行级分页，段落自然在行边界处跨页。

/// 段评气泡的尺寸常量。
///
/// 【重要】分页引擎算高度、渲染端画气泡，两边的数字必须完全一致，
/// 否则会出现「最后一页底部被裁掉」或者「每页少排一行」。
/// 所以这里定义一次，两边都引用。
const double kCommentBubbleHeight = 24.0;
const double kCommentBubbleTopSpacing = 6.0;
const double kCommentBubbleTotalHeight =
    kCommentBubbleHeight + kCommentBubbleTopSpacing;

/// 段评（段落评论）标记
///
/// 书源会把段评内联在正文里，形如：
/// ```
/// <img src="data:image/svg+xml;base64,<气泡SVG>,{"style":"TEXT","type":"qd",
///      "click":"showCmt(1044444421,872830391,3,1791160048465)"}">
/// ```
/// - 气泡 SVG 里的 `<text>` 就是评论条数；
/// - `click` 是点击时要交给后端执行的 JS，后端执行后通过 WebSocket
///   推送 `startBrowser` / `startBrowserdp`，客户端再打开段评页。
class ParagraphComment {
  const ParagraphComment({
    required this.count,
    required this.click,
    this.style = 'TEXT',
  });

  /// 气泡上显示的数字（评论条数）
  final String count;

  /// 点击时要执行的 JS 表达式，例如 `showCmt(...)`
  final String click;

  /// 书源给的样式标识（TEXT / 其它）
  final String style;

  bool get isTappable => click.trim().isNotEmpty;
}

/// 段落（源文本级别，不跨页拆分）
class ReaderParagraph {
  const ReaderParagraph({
    required this.index,
    required this.text,
    required this.startPosition,
    required this.endPosition,
    this.isTitle = false,
    this.comments = const [],
  });

  final int index;
  final String text;
  final int startPosition;
  final int endPosition;
  final bool isTitle;

  /// 本段携带的段评
  final List<ParagraphComment> comments;
}

/// 单行文本（排版引擎输出，段落被拆为多行）
class TextLine {
  const TextLine({
    required this.paragraphIndex,
    required this.text,
    required this.startOffset,
    required this.endOffset,
    required this.isTitle,
    required this.isFirstLineOfParagraph,
    required this.height,
    this.isLastLineOfParagraph = false,
    this.comments = const [],
  });

  /// 所属段落的索引
  final int paragraphIndex;

  /// 本行显示的文本内容
  final String text;

  /// 在段落原文中的起始字符偏移
  final int startOffset;

  /// 在段落原文中的结束字符偏移
  final int endOffset;

  /// 是否标题行
  final bool isTitle;

  /// 是否段落首行（需要首行缩进）
  final bool isFirstLineOfParagraph;

  /// 是否段落末行
  final bool isLastLineOfParagraph;

  /// 行高（fontSize * lineHeight）
  final double height;

  /// 段评（只挂在段落末行上，渲染在正文下方）
  final List<ParagraphComment> comments;

  TextLine copyWith({
    String? text,
    int? startOffset,
    int? endOffset,
    bool? isFirstLineOfParagraph,
    bool? isLastLineOfParagraph,
    double? height,
    List<ParagraphComment>? comments,
  }) {
    return TextLine(
      paragraphIndex: paragraphIndex,
      text: text ?? this.text,
      startOffset: startOffset ?? this.startOffset,
      endOffset: endOffset ?? this.endOffset,
      isTitle: isTitle,
      isFirstLineOfParagraph:
          isFirstLineOfParagraph ?? this.isFirstLineOfParagraph,
      isLastLineOfParagraph: isLastLineOfParagraph ?? this.isLastLineOfParagraph,
      height: height ?? this.height,
      comments: comments ?? this.comments,
    );
  }
}

/// 页面（由多行 TextLine 组成）
class PageSlice {
  const PageSlice({
    required this.lines,
    required this.startPosition,
    required this.endPosition,
    required this.chapterIndex,
  });

  /// 页面内所有行
  final List<TextLine> lines;

  /// 章节内起始位置（字符偏移）
  final int startPosition;

  /// 章节内结束位置（字符偏移）
  final int endPosition;

  /// 所属章节索引
  final int chapterIndex;

  /// 段落 → 首次出现的页码 映射（用于 TTS 定位等）
  Map<int, int> buildParagraphLookup() {
    final lookup = <int, int>{};
    for (final line in lines) {
      lookup.putIfAbsent(line.paragraphIndex, () => 0);
    }
    return lookup;
  }
}

/// 章节排版结果
class ChapterLayout {
  const ChapterLayout({
    required this.paragraphs,
    required this.pages,
    required this.paragraphPageLookup,
    required this.chapterIndex,
    required this.contentHash,
  });

  final List<ReaderParagraph> paragraphs;
  final List<PageSlice> pages;
  final Map<int, int> paragraphPageLookup;
  final int chapterIndex;
  final int contentHash;

  /// 生成缓存 key
  ///
  /// 字体族/字重也会影响换行结果，必须进 key，否则换字体后仍命中旧排版。
  static String cacheKey(
    int chapterIndex,
    int contentHash,
    double fontSize,
    double lineHeight,
    double width,
    double height,
    String pageMode, {
    String fontFamily = 'default',
    bool bold = false,
  }) {
    return '$chapterIndex|$contentHash|'
        '${fontSize.toStringAsFixed(2)}|'
        '${lineHeight.toStringAsFixed(2)}|'
        '${width.toStringAsFixed(1)}|'
        '${height.toStringAsFixed(1)}|'
        '$pageMode|$fontFamily|${bold ? 1 : 0}';
  }
}
