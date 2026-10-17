/// 书源的「流式排版」通用算法 —— 分类列表和登录界面用的是同一套。
///
/// 【为什么抽成一个通用的】实测书源返回的两类 UI 描述结构完全同源：
///
/// 分类（`/getBookSourcesExploreUrl` 的 `found`）：
///   `[{"title":"小说·共享章节数量","url":"@js:...","style":{"layout_flexBasisPercent":0.4}}]`
/// 登录界面（`/getSourcesloginui`）：
///   `[{"name":"账号管理","type":"button","action":"_login()","style":{"layout_flexBasisPercent":0.4}}]`
///
/// 两边的 `style.layout_flexBasisPercent` 含义一样——「这一项该占整行的百分之几」。
/// 官方客户端就是拿它分行的：`1` 独占一行（分组标题）、`0.4` 一行两个、
/// `0.25` 一行四个。行**内**不按比例分宽度，而是各自按内容宽度铺开、
/// 放不下就横向滑动（参考图里知秋第二行第二个胶囊就是被右边缘裁掉的）。
/// 所以这里只负责「切行」，行内渲染交给调用方。
library;

/// 把一串项按「占整行比例」切成若干行。
///
/// 规则就是 flexbox 的换行算法：
///   - 一行里比例累加不超过 1 就继续塞，放不下就换行；
///   - 占到正好 1（或更多）时立刻收行；
///   - [wrapBeforeOf] 为真的项强制另起一行（实测 `layout_wrapBefore` 有 7 处）。
///
/// 传入的 [basisOf] 必须是**已经清洗过**的比例（正数、≤1）；脏值在各自的
/// 模型里就回落成默认值了（实测有 102 个分类项写的是 `-1`）。
List<List<T>> packFlexRows<T>(
  List<T> items,
  double Function(T item) basisOf, {
  bool Function(T item)? wrapBeforeOf,
}) {
  final rows = <List<T>>[];
  var current = <T>[];
  var used = 0.0;

  void flush() {
    if (current.isNotEmpty) rows.add(current);
    current = <T>[];
    used = 0.0;
  }

  for (final item in items) {
    if ((wrapBeforeOf?.call(item) ?? false) && current.isNotEmpty) flush();
    final b = basisOf(item);
    if (current.isNotEmpty && used + b > 1.0001) flush();
    current.add(item);
    used += b;
    if (used >= 0.9999) flush();
  }
  flush();
  return rows;
}
