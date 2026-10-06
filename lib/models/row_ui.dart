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

  const RowUi({
    required this.name,
    this.type = 'text',
    this.action,
    this.style,
    this.defaultValue = '',
  });

  factory RowUi.fromJson(Map<String, dynamic> json) {
    return RowUi(
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? 'text',
      action: json['action']?.toString(),
      style: json['style'] is Map<String, dynamic>
          ? json['style'] as Map<String, dynamic>
          : null,
      defaultValue: json['default']?.toString() ?? '',
    );
  }

  bool get isButton => type == 'button';
  bool get isPassword => type == 'password';
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
