import 'dart:convert';

/// 发现页的一个「分类项」。
///
/// 【为什么不能只用 title + url 两个字段】书源返回的分类项里还有两样东西，
/// 缺了它们这一页就没法正确渲染 —— 这两点都是拿真实后端逐源验证过的：
///
/// 1. `style.layout_flexBasisPercent` —— 这一项该占整行的百分之几。
///    官方客户端按它做**流式排版**：0.25 是一行四个，0.4 是一行两个半，
///    1.0 是独占一整行的分组标题。少了这个字段，知秋终版那类书源的分类
///    会被排成一条又长又扁的横向列表，和官方观感完全不同。
///    账号里 86 个开了发现的书源、4000 个分类项实测分布：
///    0.25(2233) / 0.29(851) / 无(277) / 1.0(246) / 0.2(132) / 0.4(104) / -1.0(102)
///    —— 0.25 是压倒性众数，所以拿它兜底。
///
/// 2. **url 为空** —— 这不是一个分类，而是一个分组标题。知秋终版有 93 个
///    （「🟥🟥🟥 共享服 🟥🟥🟥」「🔴 玄幻 🔴」……）。参考图里那一排"红方块"
///    就是 🟥 这个 emoji 本身，不是图片。点它没有任何意义，更不能拿标题去
///    当 url 请求 —— 后端会真的拿着「🟥🟥🟥 共享服 🟥🟥🟥」去跑书源规则。
///    大灰狼聚合那类源还有 `type: "select"` 的项（线路/模式/频道），同理不可点。
class ExploreCategory {
  const ExploreCategory({
    required this.title,
    required this.url,
    this.basis = defaultBasis,
    this.type,
    this.wrapBefore = false,
  });

  final String title;
  final String url;

  /// 占整行的比例，取自 `style.layout_flexBasisPercent`。
  final double basis;

  /// 控件类型（`select` 等）。非空表示这是个选择器，不是分类。
  final String? type;

  /// `style.layout_wrapBefore`：这一项必须另起一行（实测有 7 处这么写）。
  final bool wrapBefore;

  /// 缺省比例：一行四个。
  ///
  /// 老写法（`玄幻::url&&都市::url`）的书源没有 style，只能用这个兜底。
  static const double defaultBasis = 0.25;

  /// 能不能点。url 为空的都是标题/控件。
  bool get selectable => url.trim().isNotEmpty;

  /// 显示用的名字。空标题在实测里没出现过，但留着兜底免得出现空白胶囊。
  String get label {
    final t = title.trim();
    return t.isEmpty ? '未命名' : t;
  }

  /// 排版用的比例：脏数据（负数、NaN、超过 1）一律回落到默认值。
  ///
  /// 【为什么要过滤】实测有 102 个项的 basis 是 `-1`（明显是书源作者笔误或
  /// "自动"的约定）。不过滤的话这一项会算出负的 flex，直接抛异常白屏。
  double get safeBasis {
    final b = basis;
    if (b.isNaN || b <= 0 || b > 1) return defaultBasis;
    return b;
  }

  /// 磁盘缓存用（发现页冷启动先贴缓存再拉网络，见 DiscoverProvider）。
  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'basis': basis,
        if (type != null) 'type': type,
        if (wrapBefore) 'wrapBefore': true,
      };

  factory ExploreCategory.fromJson(Map<String, dynamic> json) =>
      ExploreCategory(
        title: (json['title'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        basis: json['basis'] is num
            ? (json['basis'] as num).toDouble()
            : defaultBasis,
        type: json['type']?.toString(),
        wrapBefore: json['wrapBefore'] == true,
      );

  /// 解析 `/getBookSourcesExploreUrl` 返回的 `data.found`。
  ///
  /// 【三种形态，缺一不可】`found` 长什么样取决于书源怎么写 `exploreUrl`。
  /// 实测账号里 86 个开了发现的书源的分布：
  ///
  /// | 形态 | 源数 | 例子 |
  /// |---|---|---|
  /// | JSON 字符串（`@js:` + `JSON.stringify`） | 70 | 知秋终版 |
  /// | `标题::url` + 换行分隔 | 1 | 🌙 半夏小说 |
  /// | `'''` 空串（该书源就没有发现页） | 15 | 69書吧 |
  ///
  /// 还有一个源（神魔小说）返回的是「数组里塞了个错误对象」，
  /// 见 [_errorFromTitle]。
  ///
  /// 【踩过的坑】重写发现页时只照抄了「字符串」和「数组」两个分支，把最常见
  /// 的 JSON 字符串漏了 —— 于是所有源都落到兜底分类上，整个发现页没书。
  /// 所以这里三个分支都要留，而且必须有真实数据支撑才能删。
  ///
  /// 返回值里的 `note` 是「书源自己报的错」（例如需要登录），
  /// 拿不到任何分类时把它显示出来，比一句「没有发现页」有用得多。
  static ({List<ExploreCategory> items, String? note}) parse(dynamic foundRaw) {
    if (foundRaw == null) return (items: const <ExploreCategory>[], note: null);

    // 分支 3：后端已经解析成对象数组
    if (foundRaw is List) return _fromJsonList(foundRaw);

    final text = foundRaw.toString().trim();
    if (text.isEmpty) return (items: const <ExploreCategory>[], note: null);

    // 分支 2：JSON 字符串
    if (text.startsWith('[')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) return _fromJsonList(decoded);
      } catch (_) {
        // 不是合法 JSON —— 继续往下试老写法，别直接返回空
      }
    }

    // 分支 1：`标题::url`，用 `&&` 或换行分隔。
    //
    // 【为什么不用 split('::')】url 里带冒号是常事（`@js:buildRequest(...)`、
    // `http://`），按 `::` 切成两段以上时只取第一段会把链接截断。
    // 用 indexOf 找第一个分隔符，后面的原样保留。
    final items = <ExploreCategory>[];
    for (final chunk in text.split(RegExp(r'(?:&&|\n)+'))) {
      final line = chunk.trim();
      if (line.isEmpty) continue;
      final sep = line.indexOf('::');
      if (sep < 0) {
        // 没写 url 的当分组标题，和 JSON 分支的约定一致
        items.add(ExploreCategory(title: line, url: ''));
        continue;
      }
      items.add(ExploreCategory(
        title: line.substring(0, sep).trim(),
        url: line.substring(sep + 2).trim(),
      ));
    }
    return (items: items, note: null);
  }

  static ({List<ExploreCategory> items, String? note}) _fromJsonList(List raw) {
    final items = <ExploreCategory>[];
    String? note;
    for (final e in raw) {
      if (e is! Map) continue;
      final title = (e['title'] ?? e['name'] ?? '').toString().trim();
      if (title.isEmpty) continue;

      // 书源自己报错时会把错误 JSON 整个塞进 title（神魔小说：
      // `{"code":401,"message":"请先登录"}`）。当成分类显示的话就是一个
      // 点了没反应的怪胶囊，用户根本不知道发生了什么 —— 抽出来当提示。
      final err = _errorFromTitle(title);
      if (err != null) {
        note ??= err;
        continue;
      }

      items.add(ExploreCategory(
        title: title,
        url: (e['url'] ?? '').toString().trim(),
        basis: _basisOf(e['style']),
        type: e['type']?.toString(),
        wrapBefore: _wrapBeforeOf(e['style']),
      ));
    }
    return (items: items, note: note);
  }

  /// `layout_flexBasisPercent` 可能是数字，也可能是字符串（火球书库写的是 `"1"`）。
  static double _basisOf(dynamic style) {
    if (style is! Map) return defaultBasis;
    final raw = style['layout_flexBasisPercent'];
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim()) ?? defaultBasis;
    return defaultBasis;
  }

  static bool _wrapBeforeOf(dynamic style) {
    if (style is! Map) return false;
    final raw = style['layout_wrapBefore'];
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    return false;
  }

  /// 从 title 里认出书源的错误负载，返回可读的错误信息，认不出来返回 null。
  static String? _errorFromTitle(String title) {
    if (!title.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(title);
      if (decoded is Map && decoded['code'] != null) {
        final msg = (decoded['message'] ?? decoded['msg'] ?? '').toString().trim();
        return msg.isEmpty ? '书源返回错误（code=${decoded['code']}）' : msg;
      }
    } catch (_) {
      // 就是个以 { 开头的普通标题，不是错误负载
    }
    return null;
  }
}
