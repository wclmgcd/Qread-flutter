/// 阅读器字体目录
///
/// 与设置面板里的「字体」一行对应（默认 / 谷歌 / 黑体 / 圆体），
/// 官方客户端还有的「宋体」收在「更多设置」里。
///
/// [family] 为 null 表示跟随系统默认字体；否则是 pubspec.yaml 里
/// `flutter.fonts[].family` 声明过的名字（字体文件放在 assets/fonts/），
/// 或者是 Android 系统字体名（如 `sans-serif`）。
///
/// 之所以要显式指定 family，是因为 Android 上不指定 fontFamily 时，
/// Flutter 会对不同字符走不同的系统回退字体，正文里会出现「有的字是黑体、
/// 有的字是宋体」的观感（也就是用户反馈的「字体不一」）。
///
/// 打包的两个字族都是「GB2312 全集子集化 + 双字重」的产物（见 tool/subset_fonts.py）：
///   ReaderSans  ← Noto Sans SC   （谷歌思源黑体）→ 面板「谷歌」
///   ReaderSerif ← Noto Serif SC  （思源宋体）    → 面板「宋体」
///   ReaderRound ← 悠哉字体 Yozai （圆润字体）    → 面板「圆体」
/// 「黑体」直接用系统黑体（Android 的 sans-serif），不额外占包体。
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

  /// 主面板「字体」一行直接展示的选项。
  ///
  /// 顺序与官方客户端一致：默认 / 谷歌 / 黑体 / 宋体 / 圆体。
  ///
  /// 【为什么「宋体」挪进来了】原来它单独收在「更多设置」抽屉里，于是
  /// 主面板的「字体」和抽屉里的「字体」各有一份选项 —— 用户要在两个地方找
  /// 同一个设置，看起来就像设置项重复了。现在全部收进主面板，
  /// 抽屉里不再出现「字体」一行。
  static const List<ReaderFont> presets = [
    ReaderFont('default', '默认', null),
    ReaderFont('google', '谷歌', 'ReaderSans'),
    ReaderFont('heiti', '黑体', 'sans-serif'),
    ReaderFont('song', '宋体', 'ReaderSerif'),
    ReaderFont('round', '圆体', 'ReaderRound'),
  ];

  /// 全部可选字体
  static const List<ReaderFont> all = presets;

  /// 历史版本用过的 id，做一次兼容映射，避免升级后设置被打回默认
  static const Map<String, String> _legacyIds = {
    'sans': 'google',
    'serif': 'song',
    'kai': 'round',
    'yuanti': 'round',
  };

  static ReaderFont byId(String? id) {
    final normalized = _legacyIds[id] ?? id;
    for (final f in all) {
      if (f.id == normalized) return f;
    }
    return presets.first;
  }

  /// 取字体族（null = 系统默认）
  static String? familyOf(String? id) => byId(id).family;
}
