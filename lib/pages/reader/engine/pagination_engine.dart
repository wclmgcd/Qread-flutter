import 'dart:convert';

import 'package:flutter/material.dart';

import 'models.dart';

/// 行级分页引擎 v6
///
/// 核心原则：分页引擎的高度计算必须与 Flutter 渲染端完全一致。
/// Flutter Text 的行框高度 = fontSize * height（TextStyle.height），
/// 所以分页引擎也用这个公式，而非 TextPainter.computeLineMetrics().height
/// （后者返回的是 baseline 间距，不包含行框的上下留白）。
///
/// v6 相比 v5 的变化：
/// 1. 默认排版参数改为与官方客户端（后端 Web 端同款）实测值对齐：
///    左右边距 0.57em、段间距 0.25em、行距 1.5、首行缩进 2 字符；
/// 2. 段评气泡按书源 SVG 的真实几何缩放，占位高度随字号变化。
class PaginationEngine {
  /// 页面布局默认值（不再硬编码，由参数覆盖）
  ///
  /// 【数值来源】官方客户端实测（正文 1 字宽 = 83.5px，屏幕宽 1179px）：
  /// - 左右边距 51px  → 51 / 83.5 ≈ 0.61em，字号 28 时约 17px
  /// - 段间距   21px  → 21 / 83.5 ≈ 0.25em，字号 28 时约 7px
  static const double defaultHorizontalPadding = 16.0;
  static const double defaultTopPadding = 10.0;
  static const double defaultBottomPadding = 10.0;
  static const double defaultHeaderBottomSpacing = 6.0;
  static const double defaultParagraphSpacing = 7.0;
  static const double defaultLineSpacing = 1.0;
  static const double defaultFirstLineIndent = 2.0;

  /// 章节头样式（与 content_renderer.dart 一致）
  ///
  /// 官方客户端里章节标题比正文小得多（约 12.6pt vs 正文 28pt），
  /// 颜色与正文相同（不是灰色），所以这里只缩字号、不换颜色。
  static const double headerFontSize = 13.0;
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

    // 段评占位高度随字号缩放（见 CommentBubbleMetrics），算一次即可。
    // 「神评论」横幅（style=FULL）比小气泡高一截，要分开算。
    final bubbleMetrics = CommentBubbleMetrics(fontSize);

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
        final isLastLine = line.isLastLineOfParagraph;
        final spacing = isLastLine ? paragraphSpacing : defaultLineSpacing;
        // 段评也占高度，必须算进来，否则末页会被裁
        final bubbleHeight = line.comments.fold<double>(
          0.0,
          (sum, c) =>
              sum +
              (c.isBanner
                  ? bubbleMetrics.bannerTotalHeight
                  : bubbleMetrics.totalHeight),
        );
        // 顺序：行框 → 气泡 → 间距。
        // 官方客户端里气泡是紧贴段末行的，段间距排在气泡**下面**，
        // 所以间距要加在气泡之后（加在前面会让气泡整体下移一个段间距）。
        final lineTotalHeight = line.height + bubbleHeight + spacing;

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

  /// 段评标记**连同外层 `<img ...>` 包装**的整块匹配。
  ///
  /// 只给 [needsHtmlRenderer] 用：判断「是不是图片流」时必须把段评整块
  /// 摘掉，否则 base64 SVG 的字符量和 `<img>` 计数会把正常小说正文
  /// 误判成图集（详见 needsHtmlRenderer 的注释）。
  static final RegExp _dpWholeTag = RegExp(
    r'<img\b[^>]*?data:image/svg\+xml;base64,[A-Za-z0-9+/=]+,\{[^}]*\}[^>]*>',
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

  /// 从段评标记里解析出「条数」「点击 JS」以及气泡 SVG 原文
  static ParagraphComment _parseComment(String base64Payload, String jsonStr) {
    var count = '';
    var bannerTag = '';
    var bannerText = '';
    String? svgSource;
    try {
      svgSource = utf8.decode(base64.decode(base64Payload.trim()));
      final texts = RegExp(r'<text[^>]*>([^<]*)</text>', caseSensitive: false)
          .allMatches(svgSource)
          .map((m) => m.group(1)!.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (texts.isNotEmpty) count = texts.first;
      // style=FULL 的横幅 SVG 有两个 <text>：标签 + 评论正文
      if (texts.length >= 2) {
        bannerTag = texts[0];
        bannerText = texts[1];
      }
    } catch (_) {}
    var click = '';
    var style = 'TEXT';
    try {
      final obj = jsonDecode(jsonStr);
      if (obj is Map) {
        // 【书源差异】「起点（段评）」类书源把要执行的 JS 放在 `click` 里，
        // 「番茄 / 大灰狼聚合」类书源放在 `js` 里。
        // 只读 click 会让番茄系段评点击无效（click 为空 → isTappable=false）。
        click = (obj['click'] ?? obj['js'] ?? obj['url'] ?? '').toString();
        style = (obj['style'] ?? 'TEXT').toString();
      }
    } catch (_) {}
    return ParagraphComment(
      count: count.isEmpty ? '·' : count,
      click: click,
      style: style,
      bubbleSvg: svgSource,
      bannerTag: bannerTag.isEmpty ? null : bannerTag,
      bannerText: bannerText.isEmpty ? null : bannerText,
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

    // 【重要】不要把章节标题塞进正文段落里。
    //
    // 渲染端的 ContentRenderer.buildChapterHeader 已经在正文上方画了一行
    // 小字标题（官方客户端就是这个位置、这个字号）。如果这里再补一段
    // isTitle 段落，标题就会被画两遍 —— 一小一大叠在一起，
    // 正是用户截图里「字体重叠」的观感。
    //
    // cleanTitle 仍然有用：上面用它剥掉正文首行重复的标题。
    final paragraphs = <ReaderParagraph>[];

    var start = 0;
    var index = 0;
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
  /// 【历史坑 1】原实现只要正文里出现 `<img>` 就返回 true，于是带段评气泡的
  /// 书源（段评是内联 `<img>`）被误判成漫画，正文被交给 flutter_html 渲染：
  /// `\n` 被 HTML 语义折叠成空格 → 段落全拼成一段、首行缩进消失，
  /// 而且只能上下滚动，翻页 / 字号 / 行距全部失效。
  ///
  /// 【历史坑 2】改成按「文字量 vs 媒体数」判断后仍然误判：段评标记是
  /// **内联 base64 SVG，一个就上千字符**（番茄/大灰狼系一章 40+ 个，
  /// 合计四五万字符），把 textOnly 挤到很小、同时把 mediaCount 抬得很高，
  /// 于是一章正常的 2300 字小说被算成「图片流」——段评和分页又全没了。
  /// 所以必须先**整块**摘掉段评标记（连同外层 `<img ...>`），再统计。
  static bool needsHtmlRenderer(String content) {
    if (!_mediaTag.hasMatch(content)) return false;
    // 连外层 <img ...> 一起摘掉。只摘 base64 部分的话，剩下的
    // `<img src="">` 壳子仍会被 _mediaTag 数进去，mediaCount 照样虚高。
    final stripped = content.replaceAll(_dpWholeTag, '');
    final textOnly = stripped
        .replaceAll(_anyTag, '')
        .replaceAll(RegExp(r'&[a-zA-Z#0-9]+;'), ' ')
        .replaceAll(_whitespace, '');
    // 正文太短 → 基本可以断定是图片流
    if (textOnly.length < 200) return true;
    final mediaCount = _mediaTag.allMatches(stripped).length;
    if (mediaCount == 0) return false;
    // 媒体元素远多于文字 → 也是图片流
    return mediaCount >= 5 && textOnly.length < mediaCount * 60;
  }
}
