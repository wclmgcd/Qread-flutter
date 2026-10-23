import 'package:flutter/material.dart';

import '../engine/bubble_geometry.dart';
import '../engine/models.dart';
import '../engine/pagination_engine.dart';
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
/// 外观完全照书源下发的 SVG 来画：圆角方框 + 左侧小尾巴，中间是评论条数。
/// 颜色不取 SVG 里写死的 #909090，而是用当前主题的次要色，
/// 这样切到深色主题时气泡也跟着变。
class CommentBubble extends StatelessWidget {
  final ParagraphComment comment;
  final ReaderTheme theme;

  /// 正文字号——气泡整体随字号缩放
  final double fontSize;

  final VoidCallback? onTap;

  const CommentBubble({
    Key? key,
    required this.comment,
    required this.theme,
    required this.fontSize,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = CommentBubbleMetrics(fontSize);
    // style=FULL 不是小气泡，而是一整条「神评论」横幅（书源 SVG 1000×108）
    if (comment.isBanner) return _buildBanner(m);

    final geo = BubbleGeometry.of(comment.bubbleSvg);

    // 把 path 的紧包围盒等比缩放到「方框边长 = m.side」
    final scale = m.side / geo.bounds.height;
    final inkWidth = geo.bounds.width * scale;

    return SizedBox(
      // 高度必须与分页引擎的 CommentBubbleMetrics.totalHeight 一致
      height: m.totalHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: m.topSpacing),
          Padding(
            // 官方客户端里气泡的墨迹距正文左边距约 0.3em，这里照搬
            padding: EdgeInsets.only(left: m.inlineGap),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: SizedBox(
                width: inkWidth,
                height: m.side,
                child: CustomPaint(
                  painter: _BubblePainter(
                    geometry: geo,
                    scale: scale,
                    color: theme.secondaryText,
                    label: comment.count,
                  ),
                ),
              ),
            ),
          ),
          // 余下的下间距用 Spacer 吃掉，避免浮点误差导致 Column 溢出
          const Spacer(),
        ],
      ),
    );
  }

  /// 「神评论」横幅（书源 style=FULL）
  ///
  /// 书源给的 SVG 是 1000×108：一个半透明白底圆角条，
  /// 左边一块红色圆角标签（神评论），右边是评论正文。
  /// 这里按同一比例用 Widget 还原 —— 直接画 SVG 的话，
  /// 里面的 `<text>` 是写死内容的位图式排版，长评论会被裁掉。
  Widget _buildBanner(CommentBubbleMetrics m) {
    // 按书源 SVG 的 108 高做等比换算
    final s = m.bannerHeight / 108;
    final tag = comment.bannerTag?.trim();
    final body = comment.bannerText?.trim() ?? '';
    // 浅色主题用半透明白（和官方一致）；深色主题下白色会刺眼，改成轻微提亮
    final isDark = theme.background.computeLuminance() < 0.5;
    final bg = Colors.white.withValues(alpha: isDark ? 0.10 : 0.55);

    return SizedBox(
      height: m.bannerTotalHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: m.topSpacing),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Container(
              height: m.bannerHeight,
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: 35 * s),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(30 * s),
              ),
              child: Row(
                children: [
                  if (tag != null && tag.isNotEmpty) ...[
                    Container(
                      height: 52 * s,
                      padding: EdgeInsets.symmetric(horizontal: 14 * s),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF06260),
                        borderRadius: BorderRadius.circular(16 * s),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 32 * s,
                          height: 1.0,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    SizedBox(width: 40 * s),
                  ],
                  Expanded(
                    child: Text(
                      body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 38 * s,
                        height: 1.2,
                        color: theme.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// 行内段评气泡 —— 紧跟在前面的文字后面，**不单独占一行**
///
/// 与 [CommentBubble] 的区别：没有上下留白、没有 Spacer，
/// 高度就是方框边长（1.02×字号），所以能和文字排在同一行，
/// 像官方 3.41 那样贴着段末文字显示。
class InlineCommentBubble extends StatelessWidget {
  final ParagraphComment comment;
  final ReaderTheme theme;
  final double fontSize;
  final VoidCallback? onTap;

  const InlineCommentBubble({
    Key? key,
    required this.comment,
    required this.theme,
    required this.fontSize,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = CommentBubbleMetrics(fontSize);
    final geo = BubbleGeometry.of(comment.bubbleSvg);
    final scale = m.side / geo.bounds.height;
    final inkWidth = geo.bounds.width * scale;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        // 气泡与前面文字的间距（官方约 0.3em）
        padding: EdgeInsets.only(left: m.inlineGap),
        child: SizedBox(
          width: inkWidth,
          height: m.side,
          child: CustomPaint(
            painter: _BubblePainter(
              geometry: geo,
              scale: scale,
              color: theme.secondaryText,
              label: comment.count,
            ),
          ),
        ),
      ),
    );
  }
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.geometry,
    required this.scale,
    required this.color,
    required this.label,
  });

  final BubbleGeometry geometry;
  final double scale;
  final Color color;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = geometry.bounds;
    canvas.save();
    // 把 path 包围盒的左上角挪到 (0,0)，再整体缩放
    canvas.translate(-bounds.left * scale, -bounds.top * scale);
    canvas.scale(scale);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..isAntiAlias = true
      ..color = color;
    canvas.drawPath(geometry.path, stroke);
    canvas.restore();

    // 条数：SVG 里 text 的 y 是基线（官方实现没处理 dominant-baseline，
    // 因此 y=38 落在 32 高方框的垂直中线上，看起来才是居中的）
    final textSize = geometry.textSize;
    final tx = geometry.textX;
    final ty = geometry.textY;
    if (label.isEmpty || textSize == null || tx == null || ty == null) return;

    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: textSize * scale,
          height: 1.0,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final dx = (tx - bounds.left) * scale - painter.width / 2;
    final dy = (ty - bounds.top) * scale -
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.color != color ||
      old.label != label ||
      old.scale != scale ||
      !identical(old.geometry, geometry);
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
    double horizontalPadding = 16.0,
    double topPadding = 10.0,
    // 与分页引擎共用同一个值：阅读页把「避开系统手势条」算进了页脚下边距，
    // 渲染端必须收同一个数，否则最后一行会被裁或底下多出一块（见 footerBottomPadding）。
    double bottomPadding = PaginationEngine.defaultBottomPadding,
    double paragraphSpacing = 7.0,
    double firstLineIndent = 2.0,
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
    ValueChanged<ParagraphComment>? onCommentTap,
    String Function(String src)? imageUrlBuilder,
    ValueChanged<String>? onImageTap,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        topPadding,
        horizontalPadding,
        // 由调用方传进来（阅读页会把它算成「安全区 − 20px」），
        // 关掉页脚时不占位。
        showBottomBar ? bottomPadding : 0.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTopBar) buildChapterHeader(chapterTitle, theme, fontFamily),
          if (showTopBar) const SizedBox(height: 6),
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
                        onCommentTap: onCommentTap,
                        imageUrlBuilder: imageUrlBuilder,
                        onImageTap: onImageTap,
                      ),
                      // 小气泡已经嵌在文字行内（见 _buildTextLine），
                      // 这里只把「神评论」横幅单独排在行下方。
                      for (final comment
                          in line.comments.where((c) => c.isBanner))
                        CommentBubble(
                          comment: comment,
                          theme: theme,
                          fontSize: fontSize,
                          onTap: onCommentTap == null
                              ? null
                              : () => onCommentTap(comment),
                        ),
                      // 有横幅时，间距排在横幅**下面**（见分页引擎里的同款注释），
                      // 否则横幅会比官方客户端低一个段间距
                      if (line.comments.any((c) => c.isBanner))
                        SizedBox(
                            height: line.isLastLineOfParagraph
                                ? paragraphSpacing
                                : 1.0),
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
  ///
  /// 官方客户端里章节标题与正文同色，只是字号小很多（约 12.6pt vs 28pt），
  /// 所以这里不再用灰色，颜色跟随主题正文色。
  ///
  /// 分页模式（buildPage）和滚动模式（ScrollReader）共用这一个实现，
  /// 两边的标题样式才不会各写一套、各长一个样。
  static Widget buildChapterHeader(
      String title, ReaderTheme theme, String? fontFamily) {
    if (title.isEmpty) return const SizedBox.shrink();
    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        height: 1.2,
        color: theme.text,
        fontFamily: fontFamily,
      ),
    );
  }

  /// 渲染正文插图。
  ///
  /// 【为什么必须走 /imageDecode，而不是 /proxypng】
  /// 阅文（起点）系书源的插图是**加密的**（形如
  /// `https://aigcc.yuewen.com/imgChapter/....webp`），必须由后端用书源的
  /// `ruleContent.imageDecode` JS 规则解密后才能显示 —— 官方客户端走的就是
  /// `POST /imageDecode`（见官方 main.dart.js 的 `b2U`/`ahY`）。
  /// 旧的 `/proxypng` 只做「转发 + 缓存」，不解密、也不带书源 header，
  /// 拿到的是一团乱码，表现就是「图一张都显示不出来」。
  ///
  /// [src] 是书源原文（可能带 `,{json}` 后缀）；[imageUrlBuilder] 负责把它
  /// 换成带 token / 书源 / header 的完整地址 —— 由阅读页注入，因为只有它
  /// 知道当前 token 和书源。
  static Widget buildContentImage({
    required String src,
    required ReaderTheme theme,
    double? height,
    String Function(String src)? imageUrlBuilder,

    /// 点图片时回调，参数是**已经拼好 token/书源/header 的最终地址**。
    ///
    /// 【为什么传的是最终 url 而不是原始 src】
    /// 查看器要拿这个地址去加载大图。原始 `src` 可能带 `,{json}` 后缀，
    /// 也可能需要 `POST /imageDecode` 解密，只有拼好的地址能直接用。
    ValueChanged<String>? onImageTap,
  }) {
    final url = imageUrlBuilder?.call(src) ?? src;
    if (url.isEmpty) return const SizedBox.shrink();

    final image = Image.network(
      url,
      fit: BoxFit.contain,
      alignment: Alignment.center,
      // 加载中给个转圈，避免版面突然跳动
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.secondaryText,
            ),
          ),
        );
      },
      // 失败时给一行提示，而不是留一片空白（否则看起来就像「图凭空没了」）
      errorBuilder: (context, error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '图片加载失败',
            style: TextStyle(fontSize: 12, color: theme.secondaryText),
          ),
        ),
      ),
    );

    // 分页模式：高度由分页引擎给定（插图独占一页），必须夹在 SizedBox 里，
    // 否则图片会按自身高度撑破页面。滚动模式不传 height，交给 ListView
    // 按宽高比自然排。
    final sized = height == null
        ? image
        : SizedBox(height: height, width: double.infinity, child: image);

    if (onImageTap == null) return sized;
    // 【为什么不加 behavior: HitTestBehavior.opaque】
    // 插图在分页模式下常常独占一整页，若让整块区域（包括图片四周的留白）
    // 都吃掉点击，用户就没法「点图片外面翻页」了。用默认的 deferToChild
    // 让命中范围恰好等于图片本身，留白照旧走翻页手势。
    return GestureDetector(
      onTap: () => onImageTap(url),
      child: sized,
    );
  }

  /// 渲染单行文本
  static Widget _buildTextLine({
    required TextLine line,
    required ReaderTheme theme,
    required double fontSize,
    required double lineHeight,
    required int ttsParagraphIndex,
    double paragraphSpacing = 7.0,
    double firstLineIndent = 2.0,
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
    ValueChanged<ParagraphComment>? onCommentTap,
    String Function(String src)? imageUrlBuilder,
    ValueChanged<String>? onImageTap,
  }) {
    // 【插图行】整行就是一张图，独占一页。
    // 高度由分页引擎给（= 正文可用高度），这里按 BoxFit.contain 缩放进框。
    if (line.isImage) {
      return Padding(
        padding: EdgeInsets.only(bottom: paragraphSpacing),
        child: buildContentImage(
          src: line.imageUrl!,
          theme: theme,
          height: line.height,
          imageUrlBuilder: imageUrlBuilder,
          onImageTap: onImageTap,
        ),
      );
    }

    final isHighlighted = line.paragraphIndex == ttsParagraphIndex;
    final isTitle = line.isTitle;
    // 标题样式必须和分页引擎用同一组常量，否则行高算错会串页。
    final effectiveFontSize =
        isTitle ? fontSize + PaginationEngine.titleFontSizeDelta : fontSize;
    final effectiveLineHeight =
        isTitle ? PaginationEngine.titleLineHeight : lineHeight;
    // 字重跟正文一致；标题的「轻微加粗」由下面的描边阴影实现
    final effectiveWeight = fontWeight;
    final effectiveColor = isHighlighted ? theme.highlight : theme.text;

    // 首行缩进
    final indentChars = isTitle ? 0 : firstLineIndent.round();
    final indentStr =
        line.isFirstLineOfParagraph ? '\u3000' * indentChars : '';
    final displayText = isTitle ? line.text : '$indentStr${line.text}';

    // 段落间距：段尾行用 paragraphSpacing，段内行 1px。
    // 有「神评论」横幅时，段末行自身不留间距 —— 横幅要紧贴段末行，
    // 段间距由调用方排在横幅**下面**，分页引擎也是按这个顺序算高度的。
    // （旧版这里仍留了段间距，渲染比预算多出一个 paragraphSpacing，
    //   横幅落在页底时会把最后一行挤出可视区。）
    final hasBanner = line.comments.any((c) => c.isBanner);
    final marginBottom = hasBanner
        ? 0.0
        : (line.isLastLineOfParagraph ? paragraphSpacing : 1.0);

    final style = TextStyle(
      fontSize: effectiveFontSize,
      color: effectiveColor,
      height: effectiveLineHeight,
      fontWeight: effectiveWeight,
      fontFamily: fontFamily,
      // 两端对齐：分页引擎按「本行剩余宽度 / 本行字数」算好的补量。
      // 阅读页顶层已把 letterSpacing 归零，所以这里给多少就是多少，
      // 不会被 Material 3 bodyMedium 的 0.25 叠加。段末行/标题行为 0。
      letterSpacing: line.justifySpacing,
      // 标题叠一层同色偏移副本模拟 Medium 字重（详见 PaginationEngine 的注释）
      shadows: isTitle
          ? [
              Shadow(
                color: effectiveColor,
                offset: PaginationEngine.titleBoldShadowOffset,
              ),
            ]
          : null,
    );

    // 小气泡**行内跟随**：直接嵌在文字流末尾（和 3.41 一样紧贴前面的内容）。
    // 「神评论」横幅（style=FULL）是整行宽的条，由调用方单独排在行下方。
    final inlineComments =
        line.comments.where((c) => !c.isBanner).toList(growable: false);

    final content = inlineComments.isEmpty
        ? Text(
            displayText,
            style: style,
            textAlign: isTitle ? TextAlign.center : null,
          )
        // 有行内段评时改用 Row：气泡是固定宽度的尾部元素，文字用
        // Flexible 吃掉剩余宽度。气泡**不可能**再被挤到下一行 ——
        // 分页只为文字行算了行高，气泡一旦换行整页就多出一行，
        // 溢出部分被 ClipRect 裁掉，表现就是页底最后一行只剩半截。
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  displayText,
                  style: style,
                  textAlign: isTitle ? TextAlign.center : null,
                  // 单行硬约束：留给气泡的宽度由分页引擎按同一个
                  // SVG 包围盒预留（见 inlineCommentBubbleWidth），
                  // 正常情况下不会触发裁切。
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
              for (final c in inlineComments)
                InlineCommentBubble(
                  comment: c,
                  theme: theme,
                  fontSize: effectiveFontSize,
                  onTap:
                      onCommentTap == null ? null : () => onCommentTap(c),
                ),
            ],
          );

    return Container(
      margin: EdgeInsets.only(bottom: marginBottom),
      // 标题要居中，Text 必须先撑满一行宽度，否则只会按内容宽度收缩。
      width: isTitle ? double.infinity : null,
      child: content,
    );
  }

  /// 渲染滚动模式的段落
  static Widget buildParagraph({
    required ReaderParagraph paragraph,
    required ReaderTheme theme,
    required double fontSize,
    required double lineHeight,
    required int ttsParagraphIndex,
    double paragraphSpacing = 7.0,
    double firstLineIndent = 2.0,
    String? fontFamily,
    FontWeight fontWeight = FontWeight.normal,
    ValueChanged<ParagraphComment>? onCommentTap,
    String Function(String src)? imageUrlBuilder,
    ValueChanged<String>? onImageTap,
  }) {
    // 【插图段】滚动模式没有「页」的概念，交给图片按自身宽高比铺满行宽。
    if (paragraph.isImage) {
      return Padding(
        padding: EdgeInsets.only(bottom: paragraphSpacing),
        child: buildContentImage(
          src: paragraph.imageUrl!,
          theme: theme,
          imageUrlBuilder: imageUrlBuilder,
          onImageTap: onImageTap,
        ),
      );
    }

    final isHighlighted = paragraph.index == ttsParagraphIndex;
    final isTitle = paragraph.isTitle;
    // 与分页引擎共用同一组标题常量（见 PaginationEngine.titleFontSizeDelta）
    final effectiveFontSize =
        isTitle ? fontSize + PaginationEngine.titleFontSizeDelta : fontSize;
    final effectiveLineHeight =
        isTitle ? PaginationEngine.titleLineHeight : lineHeight;
    // 字重跟正文一致；标题的「轻微加粗」由下面的描边阴影实现
    final effectiveWeight = fontWeight;

    // 首行缩进 / 段间距改为跟随阅读设置
    final indentChars = isTitle ? 0 : firstLineIndent.round();
    final indentStr = '\u3000' * indentChars;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: EdgeInsets.only(bottom: paragraphSpacing),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          // 标题居中：先撑满一行宽度，textAlign 才有居中效果
          width: isTitle ? double.infinity : null,
          decoration: BoxDecoration(
            color: isHighlighted ? theme.highlight : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: isTitle
                      ? paragraph.text
                      : '$indentStr${paragraph.text}',
                ),
                // 小气泡行内跟随（和 3.41 一致）
                for (final c
                    in paragraph.comments.where((c) => !c.isBanner))
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: InlineCommentBubble(
                      comment: c,
                      theme: theme,
                      fontSize: effectiveFontSize,
                      onTap: onCommentTap == null
                          ? null
                          : () => onCommentTap(c),
                    ),
                  ),
              ],
            ),
            textAlign: isTitle ? TextAlign.center : TextAlign.justify,
            style: TextStyle(
              fontSize: effectiveFontSize,
              color: theme.text,
              height: effectiveLineHeight,
              fontWeight: effectiveWeight,
              fontFamily: fontFamily,
              // 标题叠一层同色偏移副本模拟 Medium 字重
              shadows: isTitle
                  ? [
                      Shadow(
                        color: theme.text,
                        offset: PaginationEngine.titleBoldShadowOffset,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
        // 只有「神评论」横幅单独占一行
        for (final comment in paragraph.comments.where((c) => c.isBanner))
          CommentBubble(
            comment: comment,
            theme: theme,
            fontSize: fontSize,
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
