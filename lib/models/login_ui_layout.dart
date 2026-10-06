import 'row_ui.dart';

/// 一行的布局结果。
class LoginUiLine {
  const LoginUiLine({required this.indices, required this.widths});

  /// 落在这一行上的条目下标（对应传进来的 `rows`）。
  final List<int> indices;

  /// 与 [indices] 一一对应的宽度。
  ///
  /// `null` 表示「不要约束，让子组件自己撑到内容宽度」——
  /// 即书源没写 `layout_flexBasisPercent` 也没写 `layout_flexGrow` 的条目。
  final List<double?> widths;
}

/// 按 `FlexboxLayout` 的语义把条目切成若干行，并算好每行的宽度。
///
/// 【为什么要自己算，而不是直接用 `Wrap`】
/// legado 的登录界面（`dialog_login.xml`）是一个 `FlexboxLayout`
/// （`flexDirection=row` + `flexWrap=wrap`），每个条目的 `style` 会被
/// `FlexChildStyle.apply()` 写进 LayoutParams，其中两个属性真正影响版面：
///
///   - `layout_flexBasisPercent` 参与**分行**：flexbox 分行时比较的是
///     flex base size —— 写了百分比就是 `容器宽 × 百分比`，没写才用内容宽度。
///     所以书源是靠它精确控制「一行放几个」的：`0.4` → 一行 2 个、
///     `0.27 / 0.33` → 一行 3 个、`0.87 / 1` → 独占整行。
///   - `layout_flexGrow` 参与**撑满**：分好行之后，把该行的剩余空间按
///     flexGrow 比例分给这些条目。书源里几乎每个按钮都写 1。
///
/// Flutter 的 `Wrap` 两件事都做不到 —— 它只用子组件的固有宽度分行，
/// 也从不拉伸。所以这里把分行和分配都算出来，再交给 `Column` + `Row` 渲染。
///
/// 这个文件**刻意不 import `package:flutter`**（只用 `dart:convert` 那条链），
/// 这样在没有 Flutter SDK 的机器上也能用独立 Dart SDK 直接跑单测 ——
/// 分行算法是整套排版里最容易出错的部分，值得真跑一遍而不是只做语法检查。
///
/// 纯函数，不依赖 `BuildContext`。
List<LoginUiLine> layoutLoginUiLines({
  required List<RowUi> rows,
  required double maxWidth,
  required double spacing,
  required double Function(RowUi row) naturalWidth,
}) {
  if (rows.isEmpty || !maxWidth.isFinite || maxWidth <= 0) {
    return const <LoginUiLine>[];
  }

  // 1. 每条的 flex base size（对应 flexbox 的 determineFlexBaseSize）
  final basis = List<double>.filled(rows.length, 0);
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row.flexBasisPercent >= 0) {
      basis[i] = maxWidth * row.flexBasisPercent;
    } else if (row.isFullWidth) {
      // 输入框是 `layout_width="match_parent"` —— flexbox 里等价于
      // flexBasis = 整个主轴长度，所以它必然独占一行。
      basis[i] = maxWidth;
    } else {
      basis[i] = naturalWidth(row);
    }
  }

  // 2. 贪心分行（对应 flexbox 的 isWrapRequired：
  //    `maxSize < currentLength + childLength` 就换行；
  //    另外 layout_wrapBefore 无条件换行）
  final lines = <List<int>>[];
  var current = <int>[];
  var currentWidth = 0.0;
  for (var i = 0; i < rows.length; i++) {
    if (current.isEmpty) {
      current.add(i);
      currentWidth = basis[i];
      continue;
    }
    final need = currentWidth + spacing + basis[i];
    if (need > maxWidth || rows[i].wrapBefore) {
      lines.add(current);
      current = <int>[i];
      currentWidth = basis[i];
    } else {
      current.add(i);
      currentWidth = need;
    }
  }
  if (current.isNotEmpty) lines.add(current);

  // 3. 行内按 flexGrow 分配剩余空间
  final result = <LoginUiLine>[];
  for (final line in lines) {
    var used = spacing * (line.length - 1);
    var growTotal = 0.0;
    for (final i in line) {
      used += basis[i];
      growTotal += rows[i].flexGrow;
    }
    final free = maxWidth - used;
    final widths = <double?>[];
    for (final i in line) {
      final grow = rows[i].flexGrow;
      double? width;
      if (grow > 0 && growTotal > 0) {
        // 参与撑满：剩余空间按 flexGrow 比例分（free <= 0 时就停在 basis）
        width = basis[i] + (free > 0 ? free * grow / growTotal : 0);
      } else if (rows[i].isFullWidth) {
        width = maxWidth;
      } else if (rows[i].flexBasisPercent >= 0) {
        // 写了百分比但没写 flexGrow：宽度固定在 basis 上
        // （legado 会给这个 TextView 设 maxLines=1 + ellipsize=end）
        width = basis[i];
      }
      // 两样都没写的：不约束，让子组件自己撑到内容宽
      widths.add(width == null ? null : width.clamp(0.0, maxWidth));
    }
    result.add(LoginUiLine(indices: line, widths: widths));
  }
  return result;
}
