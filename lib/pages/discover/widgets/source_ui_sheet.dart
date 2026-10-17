import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../models/flex_rows.dart';
import '../../../models/source_ui.dart';
import '../../../providers/discover_provider.dart';

/// 弹出书源自定义界面（登录 / 设置）。
///
/// 【为什么要有这个】书源可以自己写一套界面（legado 的 `loginUi`），
/// 内容是书源里的 JS 算出来的 —— 实测知秋终版 61 项（账号 / 发现页模式 /
/// 发现页小说频道 / 排序 / 段评设置 / TTS音色 / 下载购买 ……），
/// 大灰狼聚合是「邮箱 + 密码 + 登录书源 + 注册书源 + 设置中心」。
/// 这些按钮点下去跑的是书源自己的 JS，客户端只能把界面画出来、
/// 把输入框的值一起提交给后端执行。
///
/// 【为什么和分类区共用一套排版】两边的数据里都有
/// `style.layout_flexBasisPercent`（占整行百分之几），含义完全一样：
/// 1 = 分组标题占满一行、0.4 = 一行两个、0.27×3 = 一行三个。
/// 所以行分组用同一个 [packFlexRows]。
///
/// 与分类区唯一的差别：这里的按钮**按占比分宽度**（参考图里「账号管理 /
/// 账号信息」是两个等宽按钮），而分类区是各自按内容宽度、放不下就横滑。
Future<void> showSourceUiSheet(
  BuildContext context, {
  required DiscoverProvider provider,
  required String accessToken,
  required String sourceUrl,
  required String sourceName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => _SourceUiSheet(
        provider: provider,
        accessToken: accessToken,
        sourceUrl: sourceUrl,
        sourceName: sourceName,
        scrollController: controller,
      ),
    ),
  );
}

class _SourceUiSheet extends StatefulWidget {
  const _SourceUiSheet({
    required this.provider,
    required this.accessToken,
    required this.sourceUrl,
    required this.sourceName,
    required this.scrollController,
  });

  final DiscoverProvider provider;
  final String accessToken;
  final String sourceUrl;
  final String sourceName;
  final ScrollController scrollController;

  @override
  State<_SourceUiSheet> createState() => _SourceUiSheetState();
}

class _SourceUiSheetState extends State<_SourceUiSheet> {
  /// 输入框的当前值。键就是书源里写的字段名（「邮箱」「TTS音色优先级」……）。
  final Map<String, TextEditingController> _fields = {};

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _syncFields();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 把书源给的默认值 / 上一次登录信息填进输入框。
  ///
  /// 【为什么要单独抽出来】执行完一个按钮后 provider 会重新拉一次界面
  /// （登录信息可能变了），这时要把新值同步进来，但又不能把用户正在输入
  /// 的内容覆盖掉 —— 所以只在控制器不存在时创建。
  void _syncFields() {
    for (final item in widget.provider.sourceUi) {
      if (!item.isField) continue;
      _fields.putIfAbsent(
        item.name,
        () => TextEditingController(text: item.value ?? ''),
      );
    }
  }

  /// 提交给后端的 `info`：所有输入框的当前值。
  ///
  /// 空值不发 —— 书源那边常按「有没有这个键」判断分支，
  /// 发一个空串过去可能被当成"用户填了空"而不是"没填"。
  String get _infoJson => jsonEncode({
        for (final e in _fields.entries)
          if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
      });

  Future<void> _run(SourceUiItem item) async {
    if (_busy) return;
    final action = item.action?.trim() ?? '';
    // 标题（没有 action 的 button）点了不该有反应
    if (action.isEmpty) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final err = await widget.provider.runSourceUiAction(
      widget.accessToken,
      widget.sourceUrl,
      action,
      info: _infoJson,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _syncFields();
    });
    messenger.showSnackBar(SnackBar(
      content: Text(err ?? '已执行：${item.label}'),
      duration: Duration(seconds: err == null ? 2 : 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.provider.sourceUi;
    // 行分组和分类区用的是同一个算法（见 flex_rows.dart）
    final rows = packFlexRows<SourceUiItem>(items, (item) => item.safeBasis);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.sourceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    '这个书源没有自定义界面',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              for (final row in rows) ...[
                _buildRow(row),
                const SizedBox(height: 8),
              ],
              // 有些书源的登录信息是一整串 token（知秋终版就是），
              // 按字段名回填不了，至少让用户能看到它存在。
              if (widget.provider.loginInfoRaw.isNotEmpty &&
                  _fields.isEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '当前登录信息：${widget.provider.loginInfoRaw}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRow(List<SourceUiItem> row) {
    // 整行只有一个字段 → 占满一行（书源里字段的 basis 基本都是 1）
    if (row.length == 1 && row.first.isField) {
      return _buildField(row.first);
    }
    // 整行只有一个标题 → 居中的小标题
    if (row.length == 1 && row.first.isHeader) {
      return _buildHeader(row.first);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < row.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            // flex 必须是正整数；占比 ×1000 保留三位小数足够
            flex: (row[i].safeBasis * 1000).round().clamp(1, 1000),
            child: row[i].isField
                ? _buildField(row[i])
                : row[i].isHeader
                    ? _buildHeader(row[i])
                    : _buildButton(row[i]),
          ),
        ],
      ],
    );
  }

  Widget _buildHeader(SourceUiItem item) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        item.label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildButton(SourceUiItem item) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Material(
      color: primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _busy ? null : () => _run(item),
        child: Container(
          height: 42,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: primary, fontSize: 13.5),
          ),
        ),
      ),
    );
  }

  Widget _buildField(SourceUiItem item) {
    final theme = Theme.of(context);
    final controller = _fields[item.name];
    return TextField(
      controller: controller,
      obscureText: item.type == 'password',
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        labelText: item.label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}
