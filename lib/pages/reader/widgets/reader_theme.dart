import 'package:flutter/material.dart';

/// 阅读器主题配置
class ReaderTheme {
  final String name;
  final Color background;
  final Color text;
  final Color secondaryText;
  final Color divider;
  final Color highlight;

  const ReaderTheme({
    required this.name,
    required this.background,
    required this.text,
    required this.secondaryText,
    required this.divider,
    required this.highlight,
  });

  // ---- 预设主题（参考 legado readConfig.json） ----

  /// 纯白
  static const white = ReaderTheme(
    name: 'white',
    background: Color(0xFFFFFFFF),
    text: Color(0xFF000000),
    secondaryText: Color(0xFF999999),
    divider: Color(0xFFE0E0E0),
    highlight: Color(0x3300A88F),
  );

  /// 羊皮纸/暖黄（原 light）
  static const light = ReaderTheme(
    name: 'light',
    background: Color(0xFFF7F1E6),
    text: Color(0xFF2D2D2D),
    secondaryText: Color(0xFF8A8175),
    divider: Color(0xFFE1D7C8),
    highlight: Color(0x3300A88F),
  );

  /// 护眼绿 —— 默认主题
  ///
  /// 【数值来源】直接取自官方客户端（后端 Web 端同款）的截图取色：
  /// 背景 rgb(209,237,209)、正文 rgb(28,31,28)、次要文字 rgb(144,144,144)。
  /// 用户要求 App 排版/样式与后端 Web 端统一，所以默认主题就是这一套。
  static const green = ReaderTheme(
    name: 'green',
    background: Color(0xFFD1EDD1),
    text: Color(0xFF1C1F1C),
    secondaryText: Color(0xFF909090),
    divider: Color(0xFFBCD5BC),
    highlight: Color(0x3300A88F),
  );

  /// 淡蓝
  static const blue = ReaderTheme(
    name: 'blue',
    background: Color(0xFFABCEE0),
    text: Color(0xFF3D4C54),
    secondaryText: Color(0xFF6B8BA0),
    divider: Color(0xFF8FB8D0),
    highlight: Color(0x3300A88F),
  );

  /// 淡紫
  static const purple = ReaderTheme(
    name: 'purple',
    background: Color(0xFFDBB8E2),
    text: Color(0xFF68516C),
    secondaryText: Color(0xFF9478A0),
    divider: Color(0xFFC8A0D2),
    highlight: Color(0x3300A88F),
  );

  /// 深色
  static const dark = ReaderTheme(
    name: 'dark',
    background: Color(0xFF101417),
    text: Color(0xFFE4E7EB),
    secondaryText: Color(0xFF8C98A5),
    divider: Color(0xFF23303A),
    highlight: Color(0x3300A88F),
  );

  /// 护眼/sepia
  static const sepia = ReaderTheme(
    name: 'sepia',
    background: Color(0xFFF4E7CF),
    text: Color(0xFF5B4636),
    secondaryText: Color(0xFF8B6F58),
    divider: Color(0xFFDCC9A8),
    highlight: Color(0x3300A88F),
  );

  /// 微信读书淡绿
  static const wechat = ReaderTheme(
    name: 'wechat',
    background: Color(0xFFC0EDC6),
    text: Color(0xFF0B0B0B),
    secondaryText: Color(0xFF6B9E72),
    divider: Color(0xFFA0D8A8),
    highlight: Color(0x3300A88F),
  );

  // ---- 所有预设主题列表 ----
  //
  // 只放 6 个：官方客户端的「背景」一行正好是 6 个圆点，多出来的会换行，
  // 面板样式就和参考图对不上了。被裁掉的「微信」「淡蓝」两个配色仍然保留
  // 成常量（老配置还能解析），需要的话可以用面板里的「自定义」取色拿到。
  static const List<ReaderTheme> presets = [
    white,
    light,
    sepia,
    green,
    purple,
    dark,
  ];

  // ---- 自定义颜色主题 ----

  /// 创建自定义颜色主题
  static ReaderTheme custom(Color bgColor) {
    final isDark = bgColor.computeLuminance() < 0.35;
    final red = (bgColor.r * 255).round();
    final green = (bgColor.g * 255).round();
    final blue = (bgColor.b * 255).round();
    return ReaderTheme(
      name: 'custom_${bgColor.toARGB32().toRadixString(16)}',
      background: bgColor,
      text: isDark ? const Color(0xFFE4E7EB) : const Color(0xFF2D2D2D),
      secondaryText: isDark ? const Color(0xFF8C98A5) : const Color(0xFF8A8175),
      divider: isDark
          ? Color.fromARGB(255, red ~/ 2, green ~/ 2, blue ~/ 2)
          : Color.fromARGB(255, (red * 0.85).round(), (green * 0.85).round(),
              (blue * 0.85).round()),
      highlight: const Color(0x3300A88F),
    );
  }

  // ---- 查找方法 ----

  static ReaderTheme byName(String name) {
    // 先查找预设
    for (final preset in presets) {
      if (preset.name == name) return preset;
    }
    // 如果是自定义颜色
    if (name.startsWith('custom_')) {
      final hexStr = name.substring(7);
      final value = int.tryParse(hexStr, radix: 16);
      if (value != null) {
        final colorValue = hexStr.length <= 6 ? (0xFF000000 | value) : value;
        return custom(Color(colorValue));
      }
    }
    return green;
  }

  static String nextTheme(String current) {
    final idx = presets.indexWhere((t) => t.name == current);
    if (idx < 0) return presets[0].name;
    return presets[(idx + 1) % presets.length].name;
  }

  /// 主题显示名
  static String displayName(String name) {
    const names = {
      'white': '纯白',
      'light': '羊皮纸',
      'sepia': '护眼',
      'green': '护眼绿',
      'wechat': '微信',
      'blue': '淡蓝',
      'purple': '淡紫',
      'dark': '深色',
    };
    if (name.startsWith('custom_')) return '自定义';
    return names[name] ?? name;
  }

  /// 主题预览色
  static Color previewColor(String name) {
    return byName(name).background;
  }
}
