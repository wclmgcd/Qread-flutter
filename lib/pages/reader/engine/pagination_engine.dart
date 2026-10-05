import 'dart:convert';

import 'package:flutter/material.dart';

import 'models.dart';

/// 行级分页引擎 v5
///
/// 核心原则：分页引擎的高度计算必须与 Flutter 渲染端完全一致。
/// Flutter Text 的行框高度 = fontSize * height（TextStyle.height），
/// 所以分页引擎也用这个公式，而非 TextPainter.computeLineMetrics().height
/// （后者返回的是 baseline 间距，不包含行框的上下留白）。
///
/// v5 相比 v4 的变化：
/// 1. 支持 fontFamily / 字重，测量与渲染用同一套字体（换字体后换行才正确）；
/// 2. 支持书源内联的段评气泡（`data:image/svg+xml` + click JS），
///    并把气泡高度计入分页，避免最后一页被裁掉；
/// 3. 修好正文分段：`<p>` 开标签、`<br>` 变体、全角空格缩进、
///    以及与章节标题重复的首行。
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
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
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
    final headerSpacing =
        (showTopBar && headerHeight > 0) ? defaultHeaderBottomSpacing : 0.0;
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
        fontFamily: fontFamily,
        fontWeight: fontWeight,
      );

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        // 行框高度 = fontSize * lineHeight（与 Text widget 渲染一致）
        // 加上行间距：段内 2px，段尾 10px
        final isLastLine = line.isLastLineOfParagraph;
        final lineMarginBottom =
            isLastLine ? paragraphSpacing : defaultLineSpacing;
        // 段评气泡也占高度，必须算进来，否则末页会被裁
        final commentHeight = line.comments.isEmpty
            ? 0.0
            : kCommentBubbleTotalHeight;
        final lineTotalHeight =
            line.height + lineMarginBottom + commentHeight;

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
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
  }) {
    final isTitle = paragraph.isTitle;
    final effectiveFontSize = isTitle ? fontSize + 4 : fontSize;
    final effectiveLineHeight = isTitle ? 1.45 : lineHeight;
    final effectiveWeight = isTitle ? FontWeight.w600 : fontWeight;
    // 行框高度 = fontSize * lineHeight（与 Text widget 一致）
    final lineBoxHeight = effectiveFontSize * effectiveLineHeight;

    // 首行缩进：根据 firstLineIndent 生成对应数量的全角空格
    final indentChars = isTitle ? 0 : firstLineIndent.round();
    final indentStr = '\u3000' * indentChars;
    final fullText = isTitle ? paragraph.text : '$indentStr${paragraph.text}';
    final indentLength = isTitle ? 0 : indentChars;

    if (paragraph.text.isEmpty) return [];

    final painter = TextPainter(
      text: TextSpan(
        text: fullText,
        style: TextStyle(
          fontSize: effectiveFontSize,
          height: effectiveLineHeight,
          fontWeight: effectiveWeight,
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

    final lineMetrics = painter.computeLineMetrics();

    if (lineMetrics.isEmpty) {
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

      final rawLineText = fullText.substring(
          lineStart.clamp(0, textLength), lineEnd.clamp(0, textLength));

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

    if (result.isEmpty) return result;

    // 修正最后一行标记，并把段评挂到末行
    result.last = result.last.copyWith(
      isLastLineOfParagraph: true,
      comments: paragraph.comments,
    );

    return result;
  }

  // ============================================================
  // 正文清洗 / 分段
  // ============================================================

  /// 块级标签（开/闭都算）—— 一律换成换行，段落才切得开
  static final RegExp _blockTag = RegExp(
    r'</?\s*(p|div|h[1-6]|li|tr|blockquote|section|article|pre|dd|dt|figcaption)\b[^>]*>',
    caseSensitive: false,
  );

  /// <br> / <br/> / <br /> / <br   >
  static final RegExp _brTag =
      RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false);

  /// 其余任意标签
  static final RegExp _anyTag = RegExp(r'<[^>]*>');

  /// 段评标记：`data:image/svg+xml;base64,<base64>,{...json...}`
  ///
  /// 书源把段评气泡内联进正文，json 里带 click（要回传后端执行的 JS）。
  /// 注意这个 src 里含未转义的引号，所以不能按标准 HTML 解析。
  static final RegExp _dpMarker = RegExp(
    r'data:image/svg\+xml;base64,([A-Za-z0-9+/=]+),(\{[^}]*\})',
    caseSensitive: false,
  );

  /// 段评占位符（私用区字符，正文里不会出现）
  static const String _dpStart = '\uE000';
  static const String _dpEnd = '\uE001';

  static final RegExp _dpPlaceholder =
      RegExp('$_dpStart(\\d+)$_dpEnd');

  /// 数字实体 &#12345; / &#x1F600;
  static final RegExp _numericEntity =
      RegExp(r'&#(x?)([0-9a-fA-F]+);', caseSensitive: false);

  /// 空白（含全角空格）
  static final RegExp _whitespace = RegExp(r'[\s\u3000]');

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

  /// 从段评标记里解析出「条数」和「点击 JS」
  static ParagraphComment _parseComment(String base64Payload, String jsonStr) {
    var count = '';
    try {
      final svg = utf8.decode(base64.decode(base64Payload.trim()));
      final m = RegExp(r'<text[^>]*>([^<]*)</text>', caseSensitive: false)
          .firstMatch(svg);
      if (m != null) count = m.group(1)!.trim();
    } catch (_) {}
    var click = '';
    var style = 'TEXT';
    try {
      final obj = jsonDecode(jsonStr);
      if (obj is Map) {
        click = (obj['click'] ?? '').toString();
        style = (obj['style'] ?? 'TEXT').toString();
      }
    } catch (_) {}
    return ParagraphComment(
      count: count.isEmpty ? '·' : count,
      click: click,
      style: style,
    );
  }

  /// 把一行里残留的段评占位符抽出来，返回 (干净文本, 段评列表)
  static (String, List<ParagraphComment>) _drainComments(
      String line, List<ParagraphComment> all) {
    final comments = <ParagraphComment>[];
    final cleaned = line.replaceAllMapped(_dpPlaceholder, (m) {
      final idx = int.tryParse(m.group(1)!);
      if (idx != null && idx >= 0 && idx < all.length) {
        comments.add(all[idx]);
      }
      return '';
    });
    return (cleaned, comments);
  }

  /// 去掉首行里与章节标题重复的部分（后端正文常把标题拼在正文开头）
  static String _stripLeadingTitle(String line, String title) {
    final titleCompact = title.replaceAll(_whitespace, '');
    if (titleCompact.isEmpty) return line;
    final lineCompact = line.replaceAll(_whitespace, '');
    if (!lineCompact.startsWith(titleCompact)) return line;
    var count = 0;
    var end = 0;
    for (var i = 0; i < line.length; i++) {
      if (!_whitespace.hasMatch(line[i])) {
        count++;
        if (count == titleCompact.length) {
          end = i + 1;
          break;
        }
      }
    }
    return end == 0 ? line : line.substring(end).trim();
  }

  /// 将 HTML/混合内容清洗为纯文本段落
  List<ReaderParagraph> _extractParagraphs(
    String content, {
    String? chapterTitle,
  }) {
    // 0. 先把段评标记摘出来，替换成占位符，稍后再按段落归位。
    final allComments = <ParagraphComment>[];
    final withPlaceholders = content.replaceAllMapped(_dpMarker, (m) {
      final comment = _parseComment(m.group(1)!, m.group(2)!);
      final idx = allComments.length;
      allComments.add(comment);
      return '$_dpStart$idx$_dpEnd';
    });

    // 1. 标签处理：
    //    - <br> 与块级标签（开/闭）→ 换行，段落才切得开；
    //    - 其余标签直接删掉（不能换成空格，否则 "对<span>方</span>" 会变成 "对 方"）。
    final plain = _decodeEntities(withPlaceholders
        .replaceAll(_brTag, '\n')
        .replaceAll(_blockTag, '\n')
        .replaceAll(_anyTag, '')
        .replaceAll('\r', ''));

    // 2. 按行切段：一行一段，空行丢弃
    final lines = plain
        .split('\n')
        .map((line) => line.replaceAll(_whitespace, ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final cleanTitle = (chapterTitle ?? '').trim();

    // 3. 去掉与章节标题重复的首行
    if (cleanTitle.isNotEmpty && lines.isNotEmpty) {
      final stripped = _stripLeadingTitle(lines.first, cleanTitle);
      if (stripped.isEmpty) {
        lines.removeAt(0);
      } else if (stripped != lines.first) {
        lines[0] = stripped;
      }
    }

    final paragraphs = <ReaderParagraph>[];
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
    var index = cleanTitle.isNotEmpty ? 1 : 0;
    for (final rawLine in lines) {
      final (drainedText, comments) = _drainComments(rawLine, allComments);
      final text = drainedText.trim();

      if (text.isEmpty && comments.isEmpty) continue;

      final end = start + text.length;
      paragraphs.add(ReaderParagraph(
        index: index,
        text: text,
        startPosition: start,
        endPosition: end,
        comments: comments,
      ));
      start = end + 1;
      index++;
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

  /// 正文里是否含嵌入式媒体标签
  static final RegExp _mediaTag = RegExp(
    r'<\s*(img|video|audio|iframe|svg|canvas|picture|embed|object)\b',
    caseSensitive: false,
  );

  /// 内容是否必须走 HTML 渲染器 —— 即「几乎没有正文、以图片/媒体为主」的内容
  /// （真正的漫画、图集、图片站）。
  ///
  /// 【历史坑】原实现只要正文里出现 `<img>` 就返回 true，于是：
  /// - 带段评气泡的书源（段评是内联 `<img>`）被误判成漫画；
  /// - 正文被交给 flutter_html 的滚动 ListView 渲染；
  /// - HTML 语义把 `\n` 折叠成空格 → 段落全部拼成一段、首行缩进消失；
  /// - 而且只能上下滚动，翻页 / 字号 / 行距全部失效。
  ///
  /// 所以判据改成「文字量」而不是「有没有图片」：只有文字少到不构成正文时，
  /// 才认为是图片流。段评气泡已经在上游被摘掉了，不会影响这里的判断。
  static bool needsHtmlRenderer(String content) {
    if (!_mediaTag.hasMatch(content)) return false;
    final textOnly = content
        .replaceAll(_anyTag, '')
        .replaceAll(RegExp(r'&[a-zA-Z#0-9]+;'), ' ')
        .replaceAll(_whitespace, '');
    // 正文太短 → 基本可以断定是图片流
    if (textOnly.length < 200) return true;
    final mediaCount = _mediaTag.allMatches(content).length;
    // 媒体元素远多于文字 → 也是图片流
    return mediaCount >= 5 && textOnly.length < mediaCount * 60;
  }
}
