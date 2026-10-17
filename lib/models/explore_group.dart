import 'explore_category.dart';

/// 发现页的「二级分组」—— 书源自己写的一个分组标题，加上它下面的三级分类。
///
/// 【为什么要切成组，而不是把所有分类平铺】官方客户端的发现页是三级结构：
///   一级 = 书源（顶栏胶囊，左右滑换源）
///   二级 = 分组标题（「共享服」「我的」「小说」「首页」…，左右滑换组）
///   三级 = 具体分类（「小说·共享章节数量」「新书强推」…，点一下换书单）
/// 二级要能**独立左右滑动**，前提是它得是一个个独立的项，所以必须先把
/// 一长串平铺的分类按分组标题切段。
///
/// 【怎么认出分组标题】书源里 `url` 为空的就是标题（见 [ExploreCategory]）。
/// 知秋终版 1433 个分类项里有 93 个这种标题，正好对应它 93 个分组。
///
/// 【标题长什么样】原文自带 emoji 装饰，比如
/// `🟥 🟥 🟥      共享服      🟥 🟥 🟥`、`🔴 玄幻 🔴`、`🔵 🔵 首页 🔵 🔵`。
/// 参考客户端是**原样居中显示**的（那些方块就是 emoji 本身，不是图片），
/// 所以这里不做任何清洗 —— 去掉了反而和官方观感不一样。
class ExploreGroup {
  const ExploreGroup({required this.title, required this.items});

  /// 分组标题原文。可能为空 —— 书源一上来就列分类、没写标题时，
  /// 这些分类会落到一个「无标题组」里。
  final String title;

  /// 这一组下的分类（只含可点的，标题和选择器已经被切走）。
  final List<ExploreCategory> items;

  /// 有没有可点的分类。没有的话这一组没必要显示（点了也出不来书）。
  bool get isUsable => items.isNotEmpty;

  /// 有标题、且有分类 —— 只有这种组才值得占用第二级的一个位置。
  bool get hasTitle => title.trim().isNotEmpty;

  /// 显示用的标题。
  String get label {
    final t = title.trim();
    return t.isEmpty ? '全部' : t;
  }
}

/// 把一长串分类按「不可点的分组标题」切成若干组。
///
/// 规则：
///   - 遇到 `url` 为空的项 → 它是标题，开新组；
///   - 普通分类 → 归到当前组；
///   - 标题之前就出现的分类 → 归到一个无标题的「首组」（`title` 为空串）。
///
/// 空组（只有标题、下面没分类）会被丢掉：实测有书源写了标题却不给分类，
/// 留在第二级就是一个滑过去什么都没有的空页。
///
/// 如果一个标题都没有，返回单个无标题组 —— 调用方据此只显示一级和三级。
List<ExploreGroup> groupExploreCategories(List<ExploreCategory> categories) {
  final groups = <ExploreGroup>[];
  var currentTitle = '';
  var current = <ExploreCategory>[];

  void flush() {
    if (current.isNotEmpty) {
      groups.add(ExploreGroup(title: currentTitle, items: List.of(current)));
    }
    current = <ExploreCategory>[];
  }

  for (final c in categories) {
    if (!c.selectable) {
      // 标题项：先把上一组收掉，再以它为名开新组
      flush();
      currentTitle = c.title;
      continue;
    }
    current.add(c);
  }
  flush();

  return groups;
}
