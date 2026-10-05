import 'package:flutter/material.dart';

/// 段评「半截式」底部弹窗的默认高度比例。
///
/// 0.72 = 占屏幕高度的 72%，上方留出约 28% 露出阅读正文
/// （对齐大灰狼书源的段评观感）。想改高矮调这一个数就行。
const double kCommentSheetHeightRatio = 0.72;

/// 「半截式」底部弹窗容器
///
/// 段评统一用这种形态：从底部升起、顶部圆角、上方露出阅读正文。
/// 只负责容器本身（高度 + 圆角 + 标题栏 + 关闭按钮 + 下拖关闭），
/// 内容由调用方给。
///
/// 用 [showHalfSheet] 打开，不要直接 push 成整页路由。
class HalfSheet extends StatelessWidget {
  const HalfSheet({
    Key? key,
    required this.child,
    this.title,
    this.ratio = kCommentSheetHeightRatio,
    this.handleColor,
  }) : super(key: key);

  final Widget child;

  /// 标题栏文字（一般就是后端推来的 title，如「番茄段评」）。
  /// 为空时不画标题栏，改画一根拖拽把手。
  final String? title;

  /// 占屏幕高度的比例
  final double ratio;

  final Color? handleColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.of(context).size.height * ratio;
    final text = (title ?? '').trim();
    final hasTitle = text.isNotEmpty;

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: Material(
          color: theme.cardColor,
          child: Column(
            children: [
              // 有标题时标题栏本身就是拖拽区（对齐截图：顶部只有一行「番茄段评」），
              // 没标题才单独画一根把手。
              if (!hasTitle)
                _buildHandle(context, theme)
              else ...[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) > 250) {
                      Navigator.of(context).maybePop();
                    }
                  },
                  child: SizedBox(
                    height: 44,
                    child: Stack(
                      children: [
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 56),
                            child: Text(
                              text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: theme.textTheme.titleMedium?.color,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 2,
                          top: 0,
                          bottom: 0,
                          child: SizedBox(
                            width: 44,
                            child: IconButton(
                              // IconButton 默认最小 48×48，会把 44 高的标题栏撑破，
                              // 这里放开约束让它服从父级尺寸。
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(Icons.close_rounded, size: 22),
                              tooltip: '关闭',
                              color: theme.colorScheme.onSurfaceVariant,
                              onPressed: () =>
                                  Navigator.of(context).maybePop(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: theme.dividerColor.withValues(alpha: 0.15),
                ),
              ],
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }

  /// 注意：这是 StatelessWidget 的普通方法，**没有** `context` 字段，
  /// 必须由调用方（build）把 context 传进来。
  Widget _buildHandle(BuildContext context, ThemeData theme) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 250) {
          Navigator.of(context).maybePop();
        }
      },
      child: SizedBox(
        height: 26,
        width: double.infinity,
        child: Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: (handleColor ?? theme.hintColor).withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// 以「半截式」底部弹窗打开 [child]。
///
/// - `isScrollControlled: true` + 固定高度，弹窗才会占满 72% 而不是默认的一半；
/// - **`enableDrag: false`（关键）**：`showModalBottomSheet` 默认会用一个
///   `GestureDetector` 包住整个弹窗来做「下拖关闭」，它会和里面的
///   WebView 抢垂直手势 —— 结果是段评内容**滚不动**（往上拖被当成拖弹窗）。
///   关掉它之后 WebView 自己正常滚动；关闭改用标题栏上的 ✕、
///   标题栏下拖（HalfSheet 自己的手势）、或点弹窗外。
/// - 遮罩透明（对齐大灰狼的观感：上方正文不压暗），但点击弹窗外仍会关闭
///   （`isDismissible` 默认 true）。
///
/// 注意：`showModalBottomSheet` 是**路由**，所以弹窗关闭时里面
/// `State.dispose()` 会正常触发（段评的回执就挂在 dispose 上）。
Future<void> showHalfSheet(
  BuildContext context, {
  required Widget child,
  String? title,
  double ratio = kCommentSheetHeightRatio,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    builder: (_) => HalfSheet(ratio: ratio, title: title, child: child),
  );
}
