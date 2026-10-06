import 'package:flutter/widgets.dart';

import '../models/login_ui_layout.dart';
import '../models/row_ui.dart';

/// 按 `loginUi` 的 flex 语义排布登录表单。
///
/// 严格保持条目顺序 —— `FlexboxLayout` 就是按 `rowUis` 的声明顺序
/// `addView` 进去的，输入框会夹在按钮中间（而不是被抽到最前面）。
///
/// 分行与宽度分配在 [layoutLoginUiLines]（`lib/models/login_ui_layout.dart`），
/// 那个文件不依赖 Flutter，可以直接用 Dart SDK 跑单测。
class FlexLoginUi extends StatelessWidget {
  const FlexLoginUi({
    super.key,
    required this.rows,
    required this.itemBuilder,
    required this.naturalWidth,
    this.spacing = 6,
    this.runSpacing = 14,
  });

  final List<RowUi> rows;
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// 条目在没有 `layout_flexBasisPercent` 时的内容宽度。
  final double Function(RowUi row) naturalWidth;

  /// 同一行内条目之间的水平间距。
  ///
  /// legado 的 `item_fillet_text.xml` 是 `android:layout_margin="3dp"`，
  /// 相邻两条相加正好 6dp —— 实测 3.41 截图里胶囊间隙 16px，
  /// 按密度换算约 6dp，吻合。
  final double spacing;

  /// 行与行之间的垂直间距。
  ///
  /// 14dp = 两侧 margin 各 3dp + `shape_space_divider` 的 8dp
  /// （`FlexboxLayout` 配了 `showDivider="middle"`）。
  /// 实测 3.41 的行间距 39px ≈ 15dp，吻合。
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final lines = layoutLoginUiLines(
          rows: rows,
          maxWidth: constraints.maxWidth,
          spacing: spacing,
          naturalWidth: naturalWidth,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var li = 0; li < lines.length; li++) ...[
              if (li > 0) SizedBox(height: runSpacing),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var k = 0; k < lines[li].indices.length; k++) ...[
                    if (k > 0) SizedBox(width: spacing),
                    _place(
                      lines[li].widths[k],
                      itemBuilder(context, lines[li].indices[k]),
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// 有确定宽度就约束住；没有就让子组件自己撑。
  ///
  /// 用 `Flexible(loose)` 而不是直接放 —— legado 的 `FlexChildStyle`
  /// 默认 `layout_flexShrink = 1`，也就是「放不下时允许收缩」，
  /// `loose` 正好给到这个语义：宽度估计偏大时收缩、偏小时不影响。
  static Widget _place(double? width, Widget child) {
    if (width == null) {
      return Flexible(fit: FlexFit.loose, child: child);
    }
    return SizedBox(width: width, child: child);
  }
}
