import 'dart:convert';

/// 章节正文里「段评标记」的编解码。
///
/// 【为什么需要这一层】
/// 段评书源把评论气泡做成**内联 SVG** 塞进正文：
/// ```
/// ...横店<img src="data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PS...,{"style":"TEXT",
///   "type":"qd","click":"showCmt(...)"}">狭小的宾馆房间，...
/// ```
/// 那串 base64 是画气泡用的 SVG，长度 500+ 字符。实测一本普通网文单章就有
/// **129 个**这样的标记（约 70 KB），于是：
///   - 章节缓存文件里全是乱码，人根本读不了；
///   - 导出成 txt 之后更没法看（用户反馈的原话就是「只留下文字」）。
///
/// 但它又是阅读器渲染段评气泡的**唯一数据源**（`PaginationEngine` 靠它生成
/// `ParagraphComment`，`SvgPathParser` 靠里面的 `<path d>` 画气泡形状）。
/// 直接从缓存里删掉，段评就会整章消失。
///
/// 【解法：正文与标记拆开放】
///   - `<index>.txt` → 干净正文（人可读、导出可读、全文搜索可搜）
///   - `<index>.cmt` → 标记原文 + 它在正文里的**插入位置**（JSON）
/// 阅读器读缓存时用 [expand] 无损还原成原始串，分页引擎一行都不用改；
/// 导出只读 `.txt`，天然干净。
///
/// 【为什么用「位置 + 原文」而不是重新拼一个标记】
/// 重新拼字符串必须复刻书源的每一个字节（引号、属性顺序、JSON 里的空格），
/// 差一个字符 `_dpWholeTag` 就匹配不上，段评会**静默消失** —— 这种 bug 极难
/// 发现。存原文 + 位置是严格可逆的，[compact] 之后 [expand] 必然逐字还原。
///
/// 【正则为什么放在这里】分页引擎、缓存服务、导出三处都要认同一套标记。
/// 各写一份迟早走岔（本仓库在 `anyImgTag` 上已经踩过一次），所以统一收到这里，
/// `PaginationEngine` 直接引用。
class ChapterMarkup {
  ChapterMarkup._();

  /// 段评标记本体：`data:image/svg+xml;base64,<base64>,{...json...}`。
  ///
  /// 注意这个 src 里含**未转义的引号**，所以不能按标准 HTML 解析。
  static final RegExp marker = RegExp(
    r'data:image/svg\+xml;base64,([A-Za-z0-9+/=]+),(\{[^}]*\})',
    caseSensitive: false,
  );

  /// 段评标记**连同外层 `<img ...>` 包装**的整块匹配。
  ///
  /// 【为什么必须整块摘】标记是内联在 `<img src="...">` 的 src 属性里的。
  /// 只把 `base64,{json}` 那段换掉的话，占位符会落在标签**内部**，紧接着
  /// 「删掉所有标签」那一步用的 `<[^>]*>` 会一路匹配到标签结尾的 `>`，
  /// 把整个 `<img>` 连同占位符一起吃掉 —— 段评一条都渲染不出来。
  static final RegExp wholeTag = RegExp(
    r'<img\b[^>]*?data:image/svg\+xml;base64,[A-Za-z0-9+/=]+,\{[^}]*\}[^>]*>',
    caseSensitive: false,
  );

  /// 任意 `<img ...>` 标签（含正文真插图）。
  ///
  /// 必须在 [wholeTag] **之后**才用 —— 段评也是 `<img>`，只是 src 是
  /// `data:image/svg+xml;base64,...`，会被先一步摘掉。走到这里还剩下的
  /// `<img>`，才是真插图。
  static final RegExp anyImgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false);

  /// sidecar 格式版本。将来要改结构就靠它让老 sidecar 自动失效。
  static const int version = 1;

  /// 段评标记的「前缀」探针。书源大小写不固定（[marker] 就是大小写不敏感的），
  /// 所以这里也按不敏感匹配，否则 `DATA:IMAGE/SVG+XML;BASE64` 会被漏掉。
  static final RegExp _markerProbe = RegExp(
    r'data:image/svg\+xml;base64',
    caseSensitive: false,
  );

  /// 正文里是否含段评标记（缓存写入前先问一句，避免无谓的字符串处理）。
  static bool hasMarkup(String raw) =>
      raw.length > 30 && _markerProbe.hasMatch(raw);

  /// 把正文里的段评整块摘掉。
  ///
  /// 返回 `(text, sidecar)`：
  ///   - [text] 干净正文；
  ///   - sidecar 为 JSON 串，没有段评时是**空串**（调用方据此决定要不要写盘）。
  ///
  /// sidecar 结构：
  /// ```json
  /// {"v":1,"h":"1a2b3c4d","n":129,"i":[[4,"<img ...>"],...]}
  /// ```
  /// `h` 是干净正文的哈希，用来判断 sidecar 是不是**过期**的（正文变了、
  /// sidecar 还是上一版的），见 [expand]。
  static ({String text, String sidecar}) compact(String raw) {
    if (raw.isEmpty || !hasMarkup(raw)) {
      return (text: raw, sidecar: '');
    }

    final buffer = StringBuffer();
    final items = <List<Object>>[];
    var last = 0;
    for (final match in wholeTag.allMatches(raw)) {
      buffer.write(raw.substring(last, match.start));
      // 位置取的是**已写出的干净正文长度** —— 正好是这条标记被摘掉的位置。
      items.add(<Object>[buffer.length, match.group(0)!]);
      last = match.end;
    }
    if (items.isEmpty) return (text: raw, sidecar: '');
    buffer.write(raw.substring(last));

    final text = buffer.toString();
    return (
      text: text,
      sidecar: jsonEncode(<String, Object>{
        'v': version,
        'h': _hash(text),
        'n': items.length,
        'i': items,
      }),
    );
  }

  /// 把 sidecar 里的段评按位置原样插回正文（阅读器读缓存时用）。
  ///
  /// 【任何一步对不上都原样返回 text】宁可少几个段评气泡，也绝不能把
  /// 半截标记插进正文 —— 那会让分页引擎切出乱七八糟的段落。所以下面每处
  /// 校验失败都直接 `return text`。
  static String expand(String text, String sidecar) {
    if (sidecar.isEmpty) return text;

    final Object? decoded;
    try {
      decoded = jsonDecode(sidecar);
    } catch (_) {
      return text;
    }
    if (decoded is! Map) return text;
    if (decoded['v'] != version) return text;
    // 正文和 sidecar 不是同一次写的（正文被更新过）→ 位置全错，丢弃。
    if (decoded['h'] != _hash(text)) return text;

    final rawItems = decoded['i'];
    if (rawItems is! List || rawItems.isEmpty) return text;
    if (decoded['n'] is int && decoded['n'] != rawItems.length) return text;

    final buffer = StringBuffer();
    var last = 0;
    for (final item in rawItems) {
      if (item is! List || item.length != 2) return text;
      final offset = item[0];
      final tag = item[1];
      if (offset is! int || tag is! String) return text;
      // 位置必须单调不减、且落在正文范围内，否则这份 sidecar 不可信。
      if (offset < last || offset > text.length) return text;
      buffer
        ..write(text.substring(last, offset))
        ..write(tag);
      last = offset;
    }
    buffer.write(text.substring(last));
    return buffer.toString();
  }

  /// 把正文里**所有** `<img>` 标签删干净（导出纯文本用）。
  ///
  /// 和 [compact] 的区别：这里连正文真插图一起删 —— 导出的是一份给人读的
  /// txt，图片地址（往往还带一段 `{"style":"FULL","type":"qd"}` 的 JSON）
  /// 留在里面只是噪声。缓存里则必须留着，阅读器要拿它渲染插图。
  static String stripImages(String text) {
    if (text.isEmpty || !text.contains('<img')) return text;
    return text.replaceAll(anyImgTag, '');
  }

  /// 32 位字符串哈希，只用来判断「正文还是不是写 sidecar 时那一份」。
  ///
  /// 【为什么不用 md5】这里只需要「变了就大概率不同」，32 位足够；而且
  /// `dart:convert` + 手写循环零依赖。
  /// 【为什么乘法系数是 31】`h < 2^32`，`h * 31 < 2^37` —— 稳稳落在
  /// IEEE-754 双精度的 53 位安全整数里，dart2js 和 AOT 算出来**完全一致**。
  /// 本仓库在 64 位字面量上踩过坑（见 `LocalCacheService.scopedKey` 的注释），
  /// 这里不能再犯。
  static String _hash(String value) {
    var h = 0;
    for (var i = 0; i < value.length; i++) {
      h = (h * 31 + value.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}
