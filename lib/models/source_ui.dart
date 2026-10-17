import 'dart:convert';

/// 书源自定义界面的一项 —— 来自 `/getSourcesloginui`。
///
/// 【这是什么】书源可以自己写一套「登录 / 设置」界面（legado 的 `loginUi`），
/// 后端把书源里的 JS 跑完，返回一个 JSON 数组描述每一项。实测：
///
/// 知秋终版（61 项）：
///   {"name":"🍎 账号 🍎",        "type":"button", "style":{"layout_flexBasisPercent":1}}
///   {"name":"账号管理",           "type":"button", "action":"_login()",      "style":{"...":0.4}}
///   {"name":"TTS音色优先级",       "type":"text",   "default":"6001,6002...", "style":{"...":1}}
/// 大灰狼聚合：
///   {"name":"邮箱",              "type":"text"}
///   {"name":"密码",              "type":"password"}
///   {"name":"♥登录书源",          "type":"button", "action":"login(true)"}
///
/// 【怎么判断一项是不是「分组标题」】没有 `action` 的 button。实测知秋的
/// 「🍎 账号 🍎」「🍎 发现页模式 🍎」都是这种 —— 它们只是小标题，点了不该有反应。
/// 这和分类里「url 为空的是标题」是同一个套路。
///
/// 【按钮怎么执行】`action` 是一段书源 JS（`_login()`、`switchSetting('段评')`、
/// `setType('all')`），由后端的 `/action` 接口在该书源的上下文里跑。
/// 界面上 text / password 字段的当前值会一起作为 `info` 提交 —— 登录就是靠这个：
/// 用户填完邮箱密码，点「登录书源」，后端把 info 存成登录信息再执行 `login(true)`。
class SourceUiItem {
  const SourceUiItem({
    required this.name,
    required this.type,
    this.action,
    this.value,
    this.basis = defaultBasis,
    this.chars = const <String>[],
  });

  /// 显示名（书源自己写的，常带 emoji）。
  final String name;

  /// `button` / `text` / `password` / `select` / `toggle` / `file`。
  final String type;

  /// 按钮要执行的 JS，标题项为空。
  final String? action;

  /// 默认值：`text` 用 `default`，其它类型用 `/getLoginInfo` 里同名的值覆盖。
  final String? value;

  /// 占整行比例，含义与分类项一致。
  final double basis;

  /// `select` 的选项。
  final List<String> chars;

  /// 缺省比例。登录界面里最常见的是 0.4（一行两个）和 0.45/0.33（一行两三个）。
  static const double defaultBasis = 0.4;

  /// 是不是输入框（要渲染成 TextField）。
  bool get isField =>
      type == 'text' ||
      type == 'password' ||
      type == 'number' ||
      type == 'file';

  /// 是不是下拉选择。
  bool get isSelect => type == 'select' || chars.isNotEmpty;

  /// 分组标题：没有 action 的 button。
  bool get isHeader => type == 'button' && (action ?? '').trim().isEmpty;

  /// 能不能点（标题不能点）。
  bool get tappable => !isHeader;

  String get label {
    final t = name.trim();
    return t.isEmpty ? '未命名' : t;
  }

  /// 排版用的比例，脏数据回落默认值（理由同 ExploreCategory.safeBasis）。
  double get safeBasis {
    final b = basis;
    if (b.isNaN || b <= 0 || b > 1) return defaultBasis;
    return b;
  }

  SourceUiItem copyWithValue(String? v) => SourceUiItem(
        name: name,
        type: type,
        action: action,
        value: v,
        basis: basis,
        chars: chars,
      );

  /// 解析 `/getSourcesloginui` 的返回。
  ///
  /// [loginInfo] 是 `/getLoginInfo` 的值（形如 `{"邮箱":"a@b.c"}`），
  /// 用来给同名的输入框回填 —— 不回填的话用户每次进设置都要重新输一遍密码。
  static List<SourceUiItem> parse(dynamic raw, {Map<String, dynamic>? loginInfo}) {
    final list = _asList(raw);
    final items = <SourceUiItem>[];
    for (final e in list) {
      if (e is! Map) continue;
      final name = (e['name'] ?? e['title'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final type = (e['type'] ?? 'button').toString().trim().toLowerCase();
      final charsRaw = e['chars'];
      final chars = charsRaw is List
          ? charsRaw.map((c) => c.toString()).where((c) => c.isNotEmpty).toList()
          : const <String>[];
      final fromLogin = loginInfo?[name];
      final value = fromLogin?.toString() ?? e['default']?.toString();
      items.add(SourceUiItem(
        name: name,
        type: type.isEmpty ? 'button' : type,
        action: e['action']?.toString(),
        value: value,
        basis: _basisOf(e['style']),
        chars: chars,
      ));
    }
    return items;
  }

  /// `/getLoginInfo` 的返回可能是 JSON 字符串、JSON 对象，也可能是空。
  static Map<String, dynamic> parseLoginInfo(dynamic raw) {
    if (raw == null) return const <String, dynamic>{};
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final text = raw.toString().trim();
    if (text.isEmpty || text == '{}') return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 不是 JSON —— 有些书源的登录信息是裸字符串（知秋的是一串 token），
      // 这种没法按字段回填，交给调用方自己决定要不要显示。
    }
    return const <String, dynamic>{};
  }

  /// 有些书源的登录信息是**裸字符串**（知秋的 `/getVariable` 返回的就是一串 token），
  /// 按字段名回填不了。保留原文是为了让界面上能显示出来。
  static String rawLoginInfo(dynamic raw) {
    if (raw == null) return '';
    if (raw is Map) return jsonEncode(raw);
    return raw.toString().trim();
  }

  static List<dynamic> _asList(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) return raw;
    final text = raw.toString().trim();
    if (text.isEmpty) return const [];
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return decoded;
    } catch (_) {
      // 不是合法 JSON：这种书源就是没有登录界面
    }
    return const [];
  }

  static double _basisOf(dynamic style) {
    if (style is! Map) return defaultBasis;
    final raw = style['layout_flexBasisPercent'];
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim()) ?? defaultBasis;
    return defaultBasis;
  }
}
