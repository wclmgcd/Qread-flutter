import 'package:flutter/material.dart';

import 'models.dart';

/// 行级分页引擎 v4
///
/// 核心原则：分页引擎的高度计算必须与 Flutter 渲染端完全一致。
/// Flutter Text 的行框高度 = fontSize * height（TextStyle.height），
/// 所以分页引擎也用这个公式，而非 TextPainter.computeLineMetrics().height
/// （后者返回的是 baseline 间距，不包含行框的上下留白）。

class PaginationEngine {
  /// 页面布局默认值（不再硬编码，由参数覆盖）
  static const double defaultHorizontalPadding = 24.0;
  static const double defaultTopPadding = 18.0;
  static const double defaultBottomPadding = 10.0;
  static const double defaultHeaderBottomSpacing = 14.0;
  static const double defaultParagraphSpacing = 10.0;
  static const double defaultLineSpacing = 2.0;
  static const double defaultFirstLineIndent = 2.0;

  /// 章节头样式（与 content_renderer.dart 一致）
  static const double headerFontSize = 12.0;
  static const double headerLineHeight = 1.2;

  /// 页脚样式（与 content_renderer.dart 一致）
  static const double footerFontSize = 11.0;
  static const double footerLineHeight = 1.2;

  /// 计算章节的完整分页布局
  ChapterLayout paginate({
    required String content,
    required String? chapterTitle,
    required int chapterIndex,
    required double fontSize,
    required double lineHeight,
    required Size viewportSize,
    required double safeTop,
    required double safeBottom,
    int targetPosition = 0,
    double paragraphSpacing = defaultParagraphSpacing,
    double firstLineIndent = defaultFirstLineIndent,
    double horizontalPadding = defaultHorizontalPadding,
    double topPadding = defaultTopPadding,
    bool showTopBar = true,
    bool showBottomBar = true,
  }) {
    // 1. 提取段落
    final paragraphs = _extractParagraphs(content, chapterTitle: chapterTitle);

    if (paragraphs.isEmpty) {
      return ChapterLayout(
        paragraphs: [],
        pages: [],
        paragraphPageLookup: {},
        chapterIndex: chapterIndex,
        contentHash: content.hashCode,
      );
    }

    // 2. 计算可用区域
    final availableWidth = viewportSize.width - horizontalPadding * 2;

    // 章节头高度：12 * 1.2 = 14.4
    final headerHeight = (showTopBar && chapterTitle?.isNotEmpty == true)
        ? headerFontSize * headerLineHeight
        : 0.0;
    final headerSpacing = (showTopBar && headerHeight > 0) ? defaultHeaderBottomSpacing : 0.0;
    // 页脚高度：11 * 1.2 = 13.2
    final footerHeight = showBottomBar ? footerFontSize * footerLineHeight : 0.0;
    final bottomPadding = showBottomBar ? defaultBottomPadding : 0.0;

    final availableHeight = viewportSize.height -
        safeTop -
        safeBottom -
        topPadding -
        bottomPadding -
        headerHeight -
        headerSpacing -
        footerHeight -
        4; // 4px 安全余量

    // 3. 逐段落 → 逐行 → 分页
    final pages = <PageSlice>[];
    final lookup = <int, int>{};
    var currentLines = <TextLine>[];
    var currentHeight = 0.0;

    void commitPage() {
      if (currentLines.isEmpty) return;
      final pageIndex = pages.length;

      int startPos = 0;
      int endPos = 0;
      for (final line in currentLines) {
        final para = paragraphs[line.paragraphIndex];
        if (startPos == 0 ||
            para.startPosition + line.startOffset < startPos) {
          startPos = para.startPosition + line.startOffset;
        }
        if (para.startPosition + line.endOffset > endPos) {
          endPos = para.startPosition + line.endOffset;
        }
      }

      pages.add(PageSlice(
        lines: List.of(currentLines),
        startPosition: startPos,
        endPosition: endPos,
        chapterIndex: chapterIndex,
      ));

      for (final line in currentLines) {
        lookup.putIfAbsent(line.paragraphIndex, () => pageIndex);
      }

      currentLines = [];
      currentHeight = 0.0;
    }

    for (final paragraph in paragraphs) {
      final lines = _splitParagraphToLines(
        paragraph: paragraph,
        fontSize: fontSize,
        lineHeight: lineHeight,
        maxWidth: availableWidth,
        firstLineIndent: firstLineIndent,
      );

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        // 行框高度 = fontSize * lineHeight（与 Text widget 渲染一致）
        // 加上行间距：段内 2px，段尾 10px
        final isLastLine = line.isLastLineOfParagraph;
        final lineMarginBottom = isLastLine ? paragraphSpacing : defaultLineSpacing;
        final lineTotalHeight = line.height + lineMarginBottom;

        if (currentLines.isNotEmpty &&
            currentHeight + lineTotalHeight > availableHeight) {
          commitPage();
        }

        currentLines.add(line);
        currentHeight += lineTotalHeight;
      }
    }

    commitPage();

    return ChapterLayout(
      paragraphs: paragraphs,
      pages: pages,
      paragraphPageLookup: lookup,
      chapterIndex: chapterIndex,
      contentHash: content.hashCode,
    );
  }

  /// 将段落拆分为 TextLine 列表
  ///
  /// TextPainter 只用于确定行拆分（哪些字符在同一行），
  /// 行高使用 fontSize * lineHeight 公式计算（与渲染端一致）。
  List<TextLine> _splitParagraphToLines({
    required ReaderParagraph paragraph,
    required double fontSize,
    required double lineHeight,
    required double maxWidth,
    double firstLineIndent = 2.0,
  }) {
    final isTitle = paragraph.isTitle;
    final effectiveFontSize = isTitle ? fontSize + 4 : fontSize;
    final effectiveLineHeight = isTitle ? 1.45 : lineHeight;
    final fontWeight = isTitle ? FontWeight.w600 : FontWeight.normal;
    // 行框高度 = fontSize * lineHeight（与 Text widget 一致）
    final lineBoxHeight = effectiveFontSize * effectiveLineHeight;

    // 首行缩进：根据 firstLineIndent 生成对应数量的全角空格
    final indentChars = isTitle ? 0 : firstLineIndent.round();
    final indentStr = '\u3000' * indentChars;
    final fullText = isTitle ? paragraph.text : '$indentStr${paragraph.text}';
    final indentLength = isTitle ? 0 : indentChars;

    final painter = TextPainter(
      text: TextSpan(
        text: fullText,
        style: TextStyle(
          fontSize: effectiveFontSize,
          height: effectiveLineHeight,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

    final lineMetrics = painter.computeLineMetrics();

    if (lineMetrics.isEmpty || paragraph.text.isEmpty) {
      return [];
    }

    int currentOffset = 0;
    final textLength = fullText.length;
    final result = <TextLine>[];

    for (int lineIndex = 0; lineIndex < lineMetrics.length; lineIndex++) {
      if (currentOffset >= textLength) break;

      final position = TextPosition(
        offset: currentOffset,
        affinity: TextAffinity.downstream,
      );
      final boundary = painter.getLineBoundary(position);

      final lineStart = boundary.start;
      final lineEnd = boundary.end;

      if (lineStart >= lineEnd || lineEnd <= currentOffset) {
        currentOffset++;
        continue;
      }

      final rawLineText =
          fullText.substring(lineStart.clamp(0, textLength), lineEnd.clamp(0, textLength));

      if (rawLineText.trim().isEmpty && lineIndex > 0) {
        currentOffset = lineEnd;
        continue;
      }

      final originalStart =
          (lineStart - indentLength).clamp(0, paragraph.text.length);
      final originalEnd =
          (lineEnd - indentLength).clamp(0, paragraph.text.length);

      String displayText;
      if (isTitle) {
        displayText = rawLineText;
      } else {
        if (lineIndex == 0) {
          displayText = rawLineText.length > indentLength
              ? rawLineText.substring(indentLength)
              : '';
        } else {
          displayText = rawLineText;
        }
      }

      if (displayText.trim().isEmpty && lineIndex > 0) {
        currentOffset = lineEnd;
        continue;
      }

      final isLastLine = lineIndex == lineMetrics.length - 1;

      result.add(TextLine(
        paragraphIndex: paragraph.index,
        text: displayText,
        startOffset: originalStart,
        endOffset: originalEnd,
        isTitle: isTitle,
        isFirstLineOfParagraph: lineIndex == 0,
        isLastLineOfParagraph: isLastLine,
        height: lineBoxHeight, // 使用公式计算，与渲染端一致
      ));

      currentOffset = lineEnd;
    }

    // 修正最后一行标记
    if (result.isNotEmpty) {
      result.last = TextLine(
        paragraphIndex: result.last.paragraphIndex,
        text: result.last.text,
        startOffset: result.last.startOffset,
        endOffset: result.last.endOffset,
        isTitle: result.last.isTitle,
        isFirstLineOfParagraph: result.last.isFirstLineOfParagraph,
        isLastLineOfParagraph: true,
        height: result.last.height,
      );
    }

    return result;
  }

  /// 块级标签的结束标记 —— 转成换行, 保证段落能被切开
  static final RegExp _blockEndTag = RegExp(
    r'<\s*/\s*(p|div|h[1-6]|li|tr|blockquote|section|article|pre)\s*>',
    caseSensitive: false,
  );

  /// <br> / <br/> / <br />
  static final RegExp _brTag = RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false);

  /// 其余任意标签
  static final RegExp _anyTag = RegExp(r'<[^>]*>');

  /// 数字实体 &#12345; / &#x1F600;
  static final RegExp _numericEntity =
      RegExp(r'&#(x?)([0-9a-fA-F]+);', caseSensitive: false);

  /// 常用命名实体
  static const Map<String, String> _namedEntities = {
    'nbsp': ' ',
    'ensp': ' ',
    'emsp': ' ',
    'thinsp': ' ',
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'ldquo': '\u201C',
    'rdquo': '\u201D',
    'lsquo': '\u2018',
    'rsquo': '\u2019',
    'hellip': '\u2026',
    'mdash': '\u2014',
    'ndash': '\u2013',
    'middot': '\u00B7',
    'times': '\u00D7',
    'divide': '\u00F7',
    'copy': '\u00A9',
    'reg': '\u00AE',
    'laquo': '\u00AB',
    'raquo': '\u00BB',
    'bull': '\u2022',
    'deg': '\u00B0',
  };

  /// 解码 HTML 实体。
  ///
  /// 书源正文里 `&nbsp;` `&#12288;` 之类很常见, 不解码会原样显示成 "&nbsp;"。
  /// 必须在剥标签之后调用 —— 否则 `&lt;script&gt;` 会先变成真标签再被剥掉。
  /// 另外 `&amp;` 必须最后解, 否则 `&amp;lt;` 会被错误还原成 "<"。
  static String _decodeEntities(String input) {
    if (!input.contains('&')) return input;
    var out = input.replaceAllMapped(_numericEntity, (m) {
      final isHex = (m.group(1) ?? '').toLowerCase() == 'x';
      final code = int.tryParse(m.group(2)!, radix: isHex ? 16 : 10);
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    });
    for (final entry in _namedEntities.entries) {
      if (entry.key == 'amp') continue;
      out = out.replaceAll('&${entry.key};', entry.value);
    }
    return out.replaceAll('&amp;', '&');
  }

  /// 将 HTML/混合内容清洗为纯文本段落
  List<ReaderParagraph> _extractParagraphs(
    String content, {
    String? chapterTitle,
  }) {
    // 标签直接删掉 (原来替换成空格, 会让 "<b>粗</b>体" 变成 "粗 体", 中文正文里
    // 凭空多出空格); 块级结束标记和 <br> 换成换行, 段落才切得开。
    final plain = _decodeEntities(content
        .replaceAll(_brTag, '\n')
        .replaceAll(_blockEndTag, '\n')
        .replaceAll(_anyTag, '')
        .replaceAll('\r', ''));
    final lines = plain
        .split(RegExp(r'\n+'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final paragraphs = <ReaderParagraph>[];
    final cleanTitle = (chapterTitle ?? '').trim();
    if (cleanTitle.isNotEmpty) {
      paragraphs.add(ReaderParagraph(
        index: 0,
        text: cleanTitle,
        startPosition: 0,
        endPosition: 0,
        isTitle: true,
      ));
    }

    var start = 0;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i];
      final end = start + text.length;
      paragraphs.add(ReaderParagraph(
        index: i + (cleanTitle.isNotEmpty ? 1 : 0),
        text: text,
        startPosition: start,
        endPosition: end,
      ));
      start = end + 1;
    }

    return paragraphs;
  }

  /// 根据位置查找页码
  int pageIndexForPosition(List<PageSlice> pages, int position) {
    if (pages.isEmpty) return 0;
    if (position >= (1 << 29)) {
      return pages.length - 1;
    }
    for (var i = 0; i < pages.length; i++) {
      if (position <= pages[i].endPosition) {
        return i;
      }
    }
    return pages.length - 1;
  }

  /// 内容是否必须走 HTML 渲染器 —— 即含有纯文本分页引擎无法呈现的元素
  /// (图片/视频/音频/iframe/SVG 等)。
  ///
  /// 原实现叫 isHtmlContent(), 正则把 `<p> <br> <div> <a> <span>` 也算 HTML,
  /// 于是绝大多数书源的正文 (几乎都带 `<br>` 或 `<p>`) 都被误判成"漫画",
  /// 被路由到滚动 ListView 里 —— 分页没了, 字号/行距/间距设置也全部失效。
  ///
  /// 但分页引擎的 _extractParagraphs() 本来就会剥标签 (它的注释写得很清楚:
  /// "将 HTML/混合内容清洗为纯文本段落"), 所以**纯文字 HTML 应该交给分页引擎**,
  /// 只有含嵌入式媒体的内容才必须用 flutter_html 渲染。
  static bool needsHtmlRenderer(String content) => RegExp(
        r'<\s*(img|video|audio|iframe|svg|canvas|picture|embed|object)\b',
        caseSensitive: false,
      ).hasMatch(content);
}
