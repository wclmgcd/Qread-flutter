/// 阅读器分页引擎数据模型
///
/// 层级结构：ChapterLayout → PageSlice → TextLine
/// 与旧版 Block 模型不同，新版采用行级分页，段落自然在行边界处跨页。

/// 段评气泡的尺寸。
///
/// 【重要】分页引擎算高度、渲染端画气泡，两边的数字必须完全一致，
/// 否则会出现「最后一页底部被裁掉」或者「每页少排一行」。
/// 所以这里定义一次，两边都引用。
///
/// 【数值来源】不是拍脑袋定的，而是从官方客户端（后端 Web 端同款）的
/// 真实排版量出来的：正文 1 个字宽 = 83.5px 时，
/// - 气泡方框 85×86px  → 方框边长 ≈ 1.02 × 字号
/// - 方框上沿距上一行行框底 17px  → 上间距 ≈ 0.20 × 字号
/// - 方框下沿距下一行行框顶 28px  → 下间距 ≈ 0.335 × 字号
/// 合计占位 1.555 × 字号，与实测的 131px（83.5 字号）吻合。
///
/// 气泡宽度不是常量：书源给的 SVG 里，方框左侧还有一条小尾巴，
/// 尾巴伸出的宽度由 path 本身决定，所以宽度 = 方框 + 尾巴。
class CommentBubbleMetrics {
  const CommentBubbleMetrics(this.fontSize);

  /// 正文字号（px / logical px）
  final double fontSize;

  /// 方框边长（书源 SVG 里方框是 32×32 单位）
  double get side => fontSize * 1.02;

  /// 方框上方的空隙
  double get topSpacing => fontSize * 0.20;

  /// 方框下方到下一行的空隙
  double get bottomSpacing => fontSize * 0.335;

  /// 气泡整体占位高度——分页引擎按这个扣减可用高度
  double get totalHeight => topSpacing + side + bottomSpacing;

  /// 方框左侧尾巴的宽度（书源 SVG：方框 x 16..48，尾巴最左到 x 8）
  double get tailWidth => side * (8 / 32);

  /// 气泡整体宽度 = 尾巴 + 方框
  double get width => side + tailWidth;

  /// 「神评论」横幅（书源 style=FULL）的高度。
  ///
  /// 书源下发的横幅 SVG 是 1000×108，按页面可用宽度铺满后高度约为
  /// 1.45 × 字号。这里刻意用「字号」而不是「页宽」来表达，是因为分页
  /// 引擎算占位时拿不到页宽 —— 两端用同一个公式才能对齐。
  double get bannerHeight => fontSize * 1.45;

  /// 横幅整体占位高度（分页引擎按这个扣减可用高度）
  double get bannerTotalHeight => topSpacing + bannerHeight + bottomSpacing;
}

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
///
/// 【书源差异】同一个功能，不同书源写法不一样，两边都得兼容：
/// | | 起点（段评）系 | 番茄 / 大灰狼聚合系 |
/// |---|---|---|
/// | JS 键名 | `click` | `js` |
/// | style 值 | `TEXT` | `text` / `FULL` |
/// | 气泡 SVG | viewBox 45×36，尾巴在左 | viewBox 25×17，尾巴在左下 |
/// 只认 `click` 会让番茄系段评「点不动」（click 为空 → 不可点）。
///
/// style 为 `FULL` 时不是气泡，而是一整条「神评论」横幅：
/// SVG 里有两个 `<text>`，第一个是红色标签文字（神评论），
/// 第二个是评论正文，需要单独排版。
class ParagraphComment {
  const ParagraphComment({
    required this.count,
    required this.click,
    this.style = 'TEXT',
    this.bubbleSvg,
    this.bannerTag,
    this.bannerText,
  });

  /// 气泡上显示的数字（评论条数）
  final String count;

  /// 点击时要执行的 JS 表达式，例如 `showCmt(...)`
  final String click;

  /// 书源给的样式标识（TEXT / 其它）
  final String style;

  /// 书源内联的气泡 SVG 源码（base64 已解码）。
  ///
  /// 官方客户端就是照这个 SVG 画的，所以渲染端也按它画，
  /// 形状/比例才和后端 Web 端一致。为 null 时退化成内置形状。
  final String? bubbleSvg;

  /// 「神评论」横幅上的标签文字（style=FULL），通常是「神评论」。
  final String? bannerTag;

  /// 「神评论」横幅上的评论正文（style=FULL）。
  final String? bannerText;

  /// 是否是「神评论」横幅（而不是小气泡）
  bool get isBanner =>
      style.toUpperCase() == 'FULL' && (bannerText?.trim().isNotEmpty ?? false);

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
    this.imageUrl,
  });

  final int index;
  final String text;
  final int startPosition;
  final int endPosition;
  final bool isTitle;

  /// 本段携带的段评
  final List<ParagraphComment> comments;

  /// 正文插图（非段评气泡）的原始 src。
  ///
  /// 【为什么要单独建「图片段」】
  /// 书源会把正文插图内联成 `<img src="...">`（阅文系是独占一行，
  /// 形如 `　　<img src="https://aigcc.yuewen.com/imgChapter/....webp,{"style":"FULL","type":"qd"}">`）。
  /// 旧实现把这些标签当普通 HTML 标签一并删掉，插图就**彻底消失** ——
  /// 这正是「书源里有图但 App 里一张都看不到」的原因。
  ///
  /// 官方客户端（main.dart.js 的 `cfX`）的做法是：按行扫描，行首是 `<img>`
  /// 且本行还没有文字片段时，让这张图**自己成为一个段落**。这里照同一套来：
  /// 图片段 [text] 为空、[imageUrl] 有值，在排版里独占一页。
  final String? imageUrl;

  /// 是否「插图段」
  bool get isImage => imageUrl != null && imageUrl!.isNotEmpty;
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
    this.justifySpacing = 0,
    this.imageUrl,
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

  /// 两端对齐时要补的字距（逻辑像素，0 = 不补）。
  ///
  /// 【为什么需要它】
  /// 中文没有词间空格，断行只能落在任意两字之间，于是每行都会剩下
  /// 「不到一个字」的空白 —— 左对齐时这段空白全堆在**右边**，看起来就是
  /// 「右侧比左侧宽」（实测：左边距 48px、右边距 101px，差一倍）。
  /// 官方 3.41 是把这个余量**摊进字距**里，让每行墨迹都顶到右边距
  /// （实测两边都是 ~48px），也就是两端对齐。
  ///
  /// 由分页引擎算好（它知道每行实测宽度和可用宽度），渲染端只负责套用；
  /// 段末行、标题行、以及为段评气泡二次拆分出来的子行一律为 0。
  final double justifySpacing;

  /// 本行是「插图行」时，这里是插图的原始 src（见 [ReaderParagraph.imageUrl]）。
  ///
  /// 插图行 [text] 恒为空、[height] 取正文可用高度 —— 也就是**独占一页**，
  /// 渲染端按 `BoxFit.contain` 把图缩放进这个框里。
  final String? imageUrl;

  /// 是否「插图行」
  bool get isImage => imageUrl != null && imageUrl!.isNotEmpty;

  TextLine copyWith({
    String? text,
    int? startOffset,
    int? endOffset,
    bool? isFirstLineOfParagraph,
    bool? isLastLineOfParagraph,
    double? height,
    List<ParagraphComment>? comments,
    double? justifySpacing,
    String? imageUrl,
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
      justifySpacing: justifySpacing ?? this.justifySpacing,
      imageUrl: imageUrl ?? this.imageUrl,
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
  /// [textScale] 是系统「字体大小」的缩放系数（MediaQuery.textScalerOf），
  /// 它直接决定每行能放几个字，也必须进 key —— Android 上调系统字号会触发
  /// config change 并重建页面（不重启 App），key 里不带它就会命中旧排版。
  ///
  /// [fontsReady] 是「内置字体是否已加载完」。pubspec 声明的字体是懒加载的，
  /// 字体没就绪时 `TextPainter` 量到的是**回退字体**的行宽，断行位置会偏。
  /// 带上它，字体就绪后 key 变化 → 自动用正确度量重排一次，而不是命中
  /// 那份用回退字体算出来的旧排版（否则会一直显示「提前断行」）。
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
    double textScale = 1.0,
    bool fontsReady = true,
  }) {
    return '$chapterIndex|$contentHash|'
        '${fontSize.toStringAsFixed(2)}|'
        '${lineHeight.toStringAsFixed(2)}|'
        '${width.toStringAsFixed(1)}|'
        '${height.toStringAsFixed(1)}|'
        '$pageMode|$fontFamily|${bold ? 1 : 0}|'
        '${textScale.toStringAsFixed(2)}|'
        '${fontsReady ? 1 : 0}';
  }
}
