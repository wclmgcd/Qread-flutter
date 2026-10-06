import 'dart:convert';

class RowUi {
  final String name;
  final String type; // "text", "password", "button"
  final String? action;
  final Map<String, dynamic>? style;

  /// 书源给输入框写的初始值（legado 的 `loginUi[].default`）。
  ///
  /// 例：知秋终版的 `{"name":"TTS音色优先级","type":"text",
  /// "default":"6001,6002,4001,4003"}` —— 不读这个字段的话，
  /// 用户看到的是空框，直接点「保存音色优先级」就把默认值清掉了。
  final String defaultValue;

  /// `style.layout_flexGrow` —— legado 的 `FlexChildStyle` 默认值是 0。
  ///
  /// 它决定**一行内的剩余空间怎么分**：值为 0 的条目保持内容宽度，
  /// 大于 0 的按比例把该行撑满。书源里几乎每个按钮都写 1。
  final double flexGrow;

  /// `style.layout_flexBasisPercent` —— 默认 -1 表示「没写」。
  ///
  /// **它决定换行点**：flexbox 分行时用的是 flex base size，
  /// 写了百分比就是 `容器宽 × 百分比`，没写才用内容宽度。
  /// 所以 `0.4` ≈ 一行放 2 个、`0.27/0.33` ≈ 一行 3 个、`1` 独占整行。
  /// （0.4 和 0.45 都是「一行 2 个」，0.87 和 1 都是「独占一行」，
  ///  作者是用这个字段精确控制「一行几个」的。）
  final double flexBasisPercent;

  /// `style.layout_wrapBefore` —— 强制这一条另起一行。
  final bool wrapBefore;

  const RowUi({
    required this.name,
    this.type = 'text',
    this.action,
    this.style,
    this.defaultValue = '',
    this.flexGrow = 0,
    this.flexBasisPercent = -1,
    this.wrapBefore = false,
  });

  factory RowUi.fromJson(Map<String, dynamic> json) {
    final style = json['style'] is Map<String, dynamic>
        ? json['style'] as Map<String, dynamic>
        : null;
    return RowUi(
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? 'text',
      action: json['action']?.toString(),
      style: style,
      defaultValue: json['default']?.toString() ?? '',
      flexGrow: _toDouble(style?['layout_flexGrow'], 0),
      flexBasisPercent: _toDouble(style?['layout_flexBasisPercent'], -1),
      wrapBefore: style?['layout_wrapBefore'] == true,
    );
  }

  static double _toDouble(Object? v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  bool get isButton => type == 'button';
  bool get isPassword => type == 'password';

  /// 是否占满整行 —— 对应 legado 的 `item_source_edit.xml`
  /// （`layout_width="match_parent"`，输入框会强制独占一行）。
  bool get isFullWidth => !isButton;
}

List<RowUi> parseLoginUi(String? raw) {
  if (raw == null || raw.isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .map((e) => RowUi.fromJson(e is Map<String, dynamic> ? e : {}))
          .toList();
    }
    return [];
  } catch (_) {
    return [];
  }
}

Map<String, String> defaultLoginData(List<RowUi> rows) {
  final data = <String, String>{};
  for (final row in rows) {
    if (!row.isButton) {
      data[row.name] = row.defaultValue;
    }
  }
  return data;
}
