/// 阅读器字体目录
///
/// 与设置面板里的「字体」一行对应（默认 / 谷歌 / 宋体 / 圆体）。
///
/// [family] 为 null 表示跟随系统默认字体；否则必须是 pubspec.yaml 里
/// `flutter.fonts[].family` 声明过的名字，字体文件放在 assets/fonts/。
///
/// 之所以要显式指定 family，是因为 Android 上不指定 fontFamily 时，
/// Flutter 会对不同字符走不同的系统回退字体，正文里会出现「有的字是黑体、
/// 有的字是宋体」的观感（也就是用户反馈的「字体不一」）。
///
/// 打包的三个字族都是「GB2312 全集子集化 + 双字重」的产物（见 tool/subset_fonts.py）：
///   ReaderSans  ← Noto Sans SC   （谷歌思源黑体）→ 面板「谷歌」
///   ReaderSerif ← Noto Serif SC  （思源宋体）    → 面板「宋体」
///   ReaderRound ← 悠哉字体 Yozai （圆润字体）    → 面板「圆体」
///
/// 每个字族都在 pubspec 里声明了 400 与 700 两个字重文件，
/// 所以「粗细」开关只要改 [FontWeight] 即可命中真粗体，不需要合成加粗。
class ReaderFont {
  const ReaderFont(this.id, this.label, this.family);

  /// 持久化用的 id
  final String id;

  /// 设置面板显示名
  final String label;

  /// 字体族，null = 系统默认
  final String? family;

  static const List<ReaderFont> presets = [
    ReaderFont('default', '默认', null),
    ReaderFont('google', '谷歌', 'ReaderSans'),
    ReaderFont('song', '宋体', 'ReaderSerif'),
    ReaderFont('round', '圆体', 'ReaderRound'),
  ];

  /// 历史版本用过的 id，做一次兼容映射，避免升级后设置被打回默认
  static const Map<String, String> _legacyIds = {
    'sans': 'google',
    'heiti': 'google',
    'serif': 'song',
    'kai': 'round',
    'yuanti': 'round',
  };

  static ReaderFont byId(String? id) {
    final normalized = _legacyIds[id] ?? id;
    for (final f in presets) {
      if (f.id == normalized) return f;
    }
    return presets.first;
  }

  /// 取字体族（null = 系统默认）
  static String? familyOf(String? id) => byId(id).family;
}
