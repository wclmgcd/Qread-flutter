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

  /// 底部留白。原来 10，反馈「页脚的时间/电量再往下一点」所以收到 6。
  /// 注意这是**安全区之内**的额外留白，再小下去会被系统手势条压住。
  static const double defaultBottomPadding = 6.0;
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

  /// 正文里的「章标题」样式（每章第一页顶部，居中加粗）
  ///
  /// 注意和 [headerFontSize] 区分：那个是**页眉**那行小字，每页都有、左对齐；
  /// 这个是**正文首段**的标题，只在本章第一页出现一次、居中加粗。
  /// 两者位置和字号都不同，所以不会像旧版本那样叠在一起。
  ///
  /// 分页端和渲染端必须用同一组常量，否则行高算错会串页。
  ///
  /// 【字号差为什么收敛到 2】原来给到 6，标题比正文大出一大截，长章节名还会
  /// 被拆成两三行，观感很跳。反馈是「比正文加粗 1 点就够了」，所以只留 2px，
  /// 「轻微加粗」改由 [titleBoldShadowOffset] 的描边实现。
  static const double titleFontSizeDelta = 2.0;
  static const double titleLineHeight = 1.45;

  /// 标题的「轻微加粗」用同色偏移阴影模拟，**不走 FontWeight**。
  ///
  /// 原因：assets/fonts 下每个字族只有 400 / 700 两档（见 pubspec.yaml），
  /// Flutter 的字重匹配只能在两档里挑最近的 ——
  ///   w500 → 落到 400（完全不加粗）
  ///   w600 → 落到 700（和 bold 一样粗）
  /// 没有中间态，所以「比正文粗一点」只能绕开字重来做。
  /// 给文字叠一层偏移 0.4px 的同色副本，笔画会略微变粗，观感接近 Medium；
  /// 关键是 **Shadow 不计入排版宽度**，所以测量端无需跟着改。
  static const Offset titleBoldShadowOffset = Offset(0.4, 0);

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
    TextScaler textScaler = TextScaler.noScaling,
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
    //
    // 【必须乘 textScaler】页眉和页脚是 Text widget 渲染的，而 Text 默认会应用
    // MediaQuery.textScalerOf(context)（也就是系统的「字体大小」设置）。
    // 这里不跟着缩放的话，系统字体调大后页眉/页脚的实际高度比预算的高，
    // 正文可用高度被高估 → 每页塞进过多行 → 正文溢出压到页脚的时间/电量上。
    final headerHeight = (showTopBar && chapterTitle?.isNotEmpty == true)
        ? textScaler.scale(headerFontSize) * headerLineHeight
        : 0.0;
    final headerSpacing =
        (showTopBar && headerHeight > 0) ? defaultHeaderBottomSpacing : 0.0;
    // 页脚高度：11 * 1.2 = 13.2
    final footerHeight = showBottomBar
        ? textScaler.scale(footerFontSize) * footerLineHeight
        : 0.0;
    final bottomPadding = showBottomBar ? defaultBottomPadding : 0.0;

    // 底部安全余量。
    //
    // 原来是固定 4px。正文是「一行一个 Text widget」拼起来的，每个 Text 的
    // 实际行高会因字体度量有零点几 px 的出入；一页十几行累积起来就可能超过
    // 4px，于是最后一行被 ClipRect 切掉半截（反馈「文字显示不全」）。
    // 改成按行高的 1/4 留余量：缓冲足够，又不至于每页都白丢一行。
    final lineBoxHeightForMargin =
        textScaler.scale(fontSize) * lineHeight;
    final safetyMargin = lineBoxHeightForMargin * 0.25;

    final availableHeight = viewportSize.height -
        safeTop -
        safeBottom -
        topPadding -
        bottomPadding -
        headerHeight -
        headerSpacing -
        footerHeight -
        safetyMargin;

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
        textScaler: textScaler,
      );

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        // 行框高度来自 _splitParagraphToLines（已按 textScaler 缩放），
        // 与 Text widget 的实际渲染高度一致。
        final isLastLine = line.isLastLineOfParagraph;
        final spacing = isLastLine ? paragraphSpacing : defaultLineSpacing;
        // 段评占位高度：
        //   - 小气泡（style=TEXT）现在是**行内跟随**（紧贴段末文字后面，和 3.41 一致）。
        //     它的高度只有 1.02×字号，小于行框高度（字号×行距），不会把行撑高，
        //     所以**不再**额外占位 —— 再加一次会让行与行之间多出一条空白。
        //   - 「神评论」横幅（style=FULL）是铺满整行宽的条，仍然单独占一行，要算高度。
        final bubbleHeight = line.comments.fold<double>(
          0.0,
          (sum, c) =>
              sum + (c.isBanner ? bubbleMetrics.bannerTotalHeight : 0.0),
        );
        // 顺序：行框 → 横幅 → 间距。
        // 官方客户端里横幅是紧贴段末行的，段间距排在横幅**下面**。
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
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    final isTitle = paragraph.isTitle;
    final effectiveFontSize =
        isTitle ? fontSize + titleFontSizeDelta : fontSize;
    final effectiveLineHeight = isTitle ? titleLineHeight : lineHeight;
    // 标题不再单独提字重（字体只有 400/700 两档，中间档拿不到），
    // 「比正文粗一点」交给 content_renderer 里的 titleBoldShadowOffset 描边。
    final effectiveWeight = fontWeight;
    // 行框高度 = 缩放后的字号 * lineHeight（与 Text widget 一致）
    //
    // 【关键】Text widget 会用 MediaQuery.textScalerOf(context) 放大字号，行框
    // 高度随之变大；而 TextPainter 默认不缩放。两边不一致的后果有两个：
    //   1. 行拆分按未缩放字号算 → 一行塞进的字比实际放得下的多 →
    //      渲染时每行被二次换行截断，正文出现「忽长忽短」的断行；
    //   2. 行高被低估 → 每页塞进行数过多 → 正文溢出，压住页脚的时间/电量。
    // 所以测量和高度都必须乘 textScaler。
    final lineBoxHeight =
        textScaler.scale(effectiveFontSize) * effectiveLineHeight;

    // 首行缩进：根据 firstLineIndent 生成对应数量的全角空格
    final indentChars = isTitle ? 0 : firstLineIndent.round();
    final indentStr = '\u3000' * indentChars;
    final fullText = isTitle ? paragraph.text : '$indentStr${paragraph.text}';
    final indentLength = isTitle ? 0 : indentChars;

    if (paragraph.text.isEmpty) return [];

    // 【段评气泡必须预留宽度 —— 但**只给段末行**预留】
    //
    // 分页时所有段评都挂在段末行（见本方法末尾的 `result.last = ...`），
    // 渲染端则把气泡作为 `WidgetSpan` **追加在段末行文字后面**
    // （见 ContentRenderer._buildTextLine）。但这里的 TextPainter 只有纯文本，
    // 完全不知道气泡占了多宽。
    //
    // 后果：段末行本来刚好放得下，渲染时被气泡一挤就换行 → 整页凭空多出一行
    // → 页面底部溢出，最后一行被裁掉一半。
    //
    // 【上一版修错了】曾经把**整段**都按 `maxWidth - bubbleReserve` 排。
    // 这样段末行确实放得下了，但代价是**该段每一行右侧都空出一截** ——
    // 用户反馈「一段文字后有段评，那这段文字右侧便有明显的空格」正是这个。
    //
    // 正确做法：正文照常按**整宽**排版，排完之后再单独把段末行拆一次
    // （见本方法末尾的「段末行为气泡让位」），只有那 1~2 行变窄。
    // 「神评论」横幅（isBanner）是独立占一行的，不在这里预留。
    final inlineComments =
        paragraph.comments.where((c) => !c.isBanner).toList(growable: false);
    final bubbleReserve = inlineComments.isEmpty
        ? 0.0
        // CommentBubbleMetrics.width 与渲染端算出的 inkWidth 一致（见
        // InlineCommentBubble），再加气泡左侧那截 0.3em 间距；末尾 2px 是
        // 浮点取整的余量。
        : CommentBubbleMetrics(effectiveFontSize).width +
            effectiveFontSize * 0.30 +
            2.0;

    final textStyle = TextStyle(
      fontSize: effectiveFontSize,
      height: effectiveLineHeight,
      fontWeight: effectiveWeight,
      fontFamily: fontFamily,
      // 【必须显式写 0】渲染端的 Text 会从 DefaultTextStyle 继承
      // Material 3 bodyMedium 的 letterSpacing(0.25)，阅读页顶层已经把它
      // 归零（见 reader_page.dart 的 DefaultTextStyle.merge）。
      // 这里显式声明 0，是为了让「分页端」的意图也写在代码里 ——
      // 两边一旦不一致，行尾最后一个字就会被挤到下一行。
      letterSpacing: 0,
    );

    final painter = TextPainter(
      text: TextSpan(text: fullText, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: null,
      // 必须与渲染端 Text widget 保持一致（Text 默认用 MediaQuery.textScalerOf）
      textScaler: textScaler,
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

      // 章标题是排版时补进去的、不属于原文任何字符区间，所以它的
      // start/end 一律记 0 —— 否则标题字数会被算进「本页覆盖到的正文位置」，
      // 污染阅读进度的区间计算。
      final originalStart = isTitle
          ? 0
          : (lineStart - indentLength).clamp(0, paragraph.text.length);
      final originalEnd = isTitle
          ? 0
          : (lineEnd - indentLength).clamp(0, paragraph.text.length);

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
        justifySpacing: _justifySpacingFor(
          lineWidth: lineMetrics[lineIndex].width,
          maxWidth: maxWidth,
          charCount: rawLineText.length,
          fontSize: effectiveFontSize,
          // 段末行按惯例不拉伸；标题是居中的，拉伸会把它推歪
          enabled: !isLastLine && !isTitle,
        ),
      ));

      currentOffset = lineEnd;
    }

    if (result.isEmpty) return result;

    // 修正最后一行标记，并把段评挂到末行
    result.last = result.last.copyWith(
      isLastLineOfParagraph: true,
      comments: paragraph.comments,
    );

    // ---- 段末行为气泡让位 ----
    //
    // 上面是整宽排出来的结果，段末行可能已经贴到右边界。渲染端会在它后面
    // 追加一个气泡 WidgetSpan，一挤就换行 → 多出一行。这里把段末行的文字
    // 按 `maxWidth - 气泡宽度` 再排一次：
    //   - 还放得下（1 行）→ 什么都不做；
    //   - 放不下（≥2 行）→ 用拆出来的子行替换原来的段末行。
    // 只有段末这几行变窄，段内其他行保持整宽。
    if (inlineComments.isNotEmpty && bubbleReserve > 0) {
      final tailMaxWidth = (maxWidth - bubbleReserve).clamp(0.0, maxWidth);
      if (tailMaxWidth > 0) {
        final last = result.last;
        // 段末行同时也是段首行时（整段只有一行），要连缩进一起量
        final measureText =
            last.isFirstLineOfParagraph ? '$indentStr${last.text}' : last.text;
        final tailPainter = TextPainter(
          text: TextSpan(text: measureText, style: textStyle),
          textDirection: TextDirection.ltr,
          maxLines: null,
          textScaler: textScaler,
        )..layout(maxWidth: tailMaxWidth);

        final tailMetrics = tailPainter.computeLineMetrics();
        if (tailMetrics.length > 1) {
          final measureLength = measureText.length;
          final subLines = <TextLine>[];
          var cursor = 0;
          var consumedChars = 0;
          for (var i = 0; i < tailMetrics.length; i++) {
            if (cursor >= measureLength) break;
            final boundary = tailPainter.getLineBoundary(
              TextPosition(offset: cursor, affinity: TextAffinity.downstream),
            );
            final s = boundary.start;
            final e = boundary.end;
            if (s >= e || e <= cursor) {
              cursor++;
              continue;
            }
            var raw = measureText.substring(
              s.clamp(0, measureLength),
              e.clamp(0, measureLength),
            );
            // 只有「段首行」才带缩进，拆出来的第一段要把缩进摘掉再显示
            if (last.isFirstLineOfParagraph && i == 0) {
              raw = raw.length > indentLength ? raw.substring(indentLength) : '';
            }
            if (raw.isEmpty) {
              cursor = e;
              continue;
            }
            subLines.add(TextLine(
              paragraphIndex: paragraph.index,
              text: raw,
              // 段评行的偏移量对阅读进度影响很小，按字数平摊即可
              startOffset: (last.startOffset + consumedChars)
                  .clamp(0, paragraph.text.length),
              endOffset: (last.startOffset + consumedChars + raw.length)
                  .clamp(0, paragraph.text.length),
              isTitle: isTitle,
              isFirstLineOfParagraph: last.isFirstLineOfParagraph && i == 0,
              isLastLineOfParagraph: i == tailMetrics.length - 1,
              height: lineBoxHeight,
              // 与主路径同一套两端对齐：让位后拆出来的**中间**行也要顶到右边距，
              // 只有最后一行不拉伸 —— 否则这一小段会明显比别的行短一截。
              justifySpacing: _justifySpacingFor(
                lineWidth: tailMetrics[i].width,
                maxWidth: tailMaxWidth,
                charCount: raw.length,
                fontSize: effectiveFontSize,
                enabled: i != tailMetrics.length - 1 && !isTitle,
              ),
            ));
            consumedChars += raw.length;
            cursor = e;
          }
          if (subLines.isNotEmpty) {
            result.removeLast();
            result.addAll(subLines);
            // 段评重新挂到（新的）末行
            result.last = result.last.copyWith(
              isLastLineOfParagraph: true,
              comments: paragraph.comments,
            );
          }
        }
      }
    }

    return result;
  }

  /// 两端对齐：算出这一行要补多少字距，才能让墨迹顶到右边距。
  ///
  /// 中文断行落在任意两字之间，每行必然剩下「不到一个字」的空白。左对齐时
  /// 这段空白全堆在行尾 —— 用户看到的就是「右侧比左侧宽，排版应该再往右走点」。
  /// 官方 3.41 把这截余量摊到字距里（实测每行墨迹都到右边距、左右边距相等），
  /// 这里照做：`补量 = 剩余宽度 / 本行字数`。
  ///
  /// - [lineWidth]：本行实测宽度（含段首缩进，因为它也在同一行里）
  /// - [charCount]：本行**渲染出来的**字符数（含缩进，渲染端会把缩进一起画）
  /// - 留 1px 余量：Flutter 的 letterSpacing 会加在每个字后面（含行尾那个），
  ///   若正好等于可用宽度，浮点误差可能让渲染端二次换行 —— 多出来那行会被
  ///   固定高度的行框裁掉，正文看起来就像「缺了一句」。1 逻辑像素的余量
  ///   肉眼不可见，但能把这个风险彻底消掉。
  /// - 上限 [fontSize] * 0.2：正常余量不到 0.1em；万一某行特别短（比如只有一个
  ///   标点），也不至于被拉成「一 个 字 一 个 字」。
  static double _justifySpacingFor({
    required double lineWidth,
    required double maxWidth,
    required int charCount,
    required double fontSize,
    required bool enabled,
  }) {
    if (!enabled || charCount <= 0 || maxWidth <= 0) return 0;
    final slack = maxWidth - lineWidth - 1.0;
    if (slack <= 0) return 0;
    final spacing = slack / charCount;
    final limit = fontSize * 0.2;
    return spacing > limit ? limit : spacing;
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
    // 0. 先把段评摘出来换成占位符，稍后再按段落归位。
    //
    // 【致命坑·段评一条都不显示的原因】段评标记是**内联在 `<img src="...">`
    // 的 src 属性里**的：
    //     ...正文。<img src="data:image/svg+xml;base64,<b64>,{json}">
    // 如果只把 `base64,{json}` 这一段换成占位符，占位符就落在 `<img ...>`
    // 标签**内部**；紧接着「删掉所有标签」那一步用的 `<[^>]*>` 会一路匹配到
    // 标签结尾的 `>`，把整个 `<img>` 连同占位符一起吃掉 —— 段评于是永远
    // 挂不到任何段落上，一条都渲染不出来。
    // 所以必须**先把整个 `<img ...段评...>` 标签换成占位符**（在删标签之前）。
    final allComments = <ParagraphComment>[];
    String placeholderOf(String b64, String json) {
      final idx = allComments.length;
      allComments.add(_parseComment(b64, json));
      return '$_dpStart$idx$_dpEnd';
    }

    var withPlaceholders = content.replaceAllMapped(_dpWholeTag, (m) {
      final inner = _dpMarker.firstMatch(m.group(0)!);
      if (inner == null) return '';
      return placeholderOf(inner.group(1)!, inner.group(2)!);
    });
    // 兜底：万一有书源把段评标记裸放在正文里（没有外层 `<img>` 包装），
    // 这里再扫一遍剩下的裸标记，避免整章段评丢失。
    withPlaceholders = withPlaceholders.replaceAllMapped(_dpMarker, (m) {
      return placeholderOf(m.group(1)!, m.group(2)!);
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

    // 【章标题】每章第一页的正文顶部，居中加粗显示本章标题（对齐官方客户端）。
    //
    // 和页眉不冲突：ContentRenderer.buildChapterHeader 画的是**页眉**那行小字
    // （每页都有、左对齐、13px）；这里补的是**正文里的标题段**，只在本章第一页
    // 出现一次、居中加粗（字号 + titleFontSizeDelta）。两者位置和字号都不同。
    //
    // 位置用 (0, 0)：标题不属于原文任何字符区间，这样正文各段的
    // startPosition/endPosition 保持和以前完全一致，阅读进度不会跳。
    final paragraphs = <ReaderParagraph>[];
    var index = 0;
    if (cleanTitle.isNotEmpty) {
      paragraphs.add(ReaderParagraph(
        index: index++,
        text: cleanTitle,
        startPosition: 0,
        endPosition: 0,
        isTitle: true,
      ));
    }

    var start = 0;
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
