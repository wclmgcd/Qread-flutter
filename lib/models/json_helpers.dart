// ignore_for_file: unused_element

// 缺失类型保留 null，避免详情刷新覆盖原类型。
int? normalizeBookType(dynamic value) {
  if (value == null) return null;
  switch (value is String ? int.tryParse(value) : value) {
    case 1:
    case 32:
      return 1;
    case 2:
    case 64:
      return 2;
    case 3:
      return 3;
    default:
      return 0;
  }
}

int? bookTypeFromSource(int? value) {
  return value != null && value >= 0 && value <= 3 ? value : null;
}

/// 有声书源经常把书存成普通文本，此时按书源声明的类型纠正：
/// 用户/内置书源类型为音频，或书源名明显是有声书（「听书」「有声」）。
int? inferBookType(int? value, {int? sourceType, String? sourceName}) {
  final type = normalizeBookType(value) ?? 0;
  if (type != 0) return type;
  if (bookTypeFromSource(sourceType) == 1) return 1;
  final name = sourceName ?? '';
  if (name.contains('听书') || name.contains('有声')) return 1;
  return type;
}

int? toInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v);
  if (v is bool) return v ? 1 : 0;
  return null;
}

double? toDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

bool? toBool(dynamic v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is double) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    return s == 'true' || s == '1' || s == 'ok';
  }
  return null;
}

String? toStringVal(dynamic v) {
  if (v == null) return null;
  if (v is String) return v;
  return v.toString();
}

List<T>? toList<T>(dynamic v, T Function(dynamic) fromJson) {
  if (v == null) return null;
  if (v is List) {
    return v.map((e) => fromJson(e)).toList();
  }
  return null;
}
