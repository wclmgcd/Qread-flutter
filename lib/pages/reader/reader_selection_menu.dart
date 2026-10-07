import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../models/replace_rule.dart';
import '../../services/api_service.dart';
import '../../services/error_text.dart';
import 'book_text_search_page.dart';

/// 阅读页「长按选中文字」后弹出的操作菜单。
///
/// 对齐 3.41 的两项（复制 / 字典），另加两项本项目扩展：
///   - 过滤：把选中的文字加进「替换净化」，替换范围自动填当前书名，
///     之后本书正文里同样的文字会被自动替换掉。
///   - 搜索：在当前书内全文搜索选中的文字。
///
/// 【为什么不用 GestureDetector 自己实现长按】
/// 文本选中（尤其是跨行、拖拽调整手柄）在 Flutter 里只有 `SelectionArea`
/// 能完整实现 —— 它内部把每一行 `Text` 注册成可选择片段。自己用
/// `TextPainter.getPositionForOffset` 反推字符位置，跨行/换行/两端对齐
/// （本项目正文有 justifySpacing）都会算错。
///
/// 【和翻页手势的关系】
/// `SelectionArea` 主要靠**长按**激活，未长按时的水平拖动仍归翻页
/// （`PagedReader` 的 HorizontalDrag）。单击则由内层的 `GestureDetector`
/// 处理 —— 见 `reader_page.dart` 里 SelectionArea 与 GestureDetector 的嵌套
/// 顺序说明。
class ReaderSelectionMenu {
  const ReaderSelectionMenu._();

  /// 系统词典通道。
  ///
  /// Android 走 `Intent.ACTION_PROCESS_TEXT`（和 3.41 一样，弹出系统里
  /// 装了词典/翻译 App 的选择器），iOS 走 `UIReferenceLibraryViewController`。
  /// 桌面 / 单元测试环境没有注册这个通道，会抛 `MissingPluginException`，
  /// 此时降级为打开网页词典。
  static const MethodChannel _dictChannel = MethodChannel('qread/dictionary');

  /// 构造选区上方的那条工具栏。
  ///
  /// [state] 是 `SelectionArea` 的 `contextMenuBuilder` 回调给的状态对象，
  /// 只用来取**选区锚点**（工具栏靠它自动定位到选区上方）。
  ///
  /// 【为什么选中文本要单独传进来，而不是从 state 上取】
  /// `SelectableRegionState` 并没有公开「取当前选中文本」的方法 —— 它只暴露
  /// `clearSelection()` / `contextMenuAnchors` / `contextMenuButtonItems` 等，
  /// 内部那个 `getSelectedContent()` 在私有的 delegate 上，外部拿不到。
  /// 官方给的通道是 `SelectionArea.onSelectionChanged`（回调 `SelectedContent?`），
  /// 所以由调用方 reader_page 捕获，这里传一个**取值闭包**进来：
  /// 每次按钮被点时才去读，不会因为工具栏被复用而读到上一次的旧文字。
  static Widget build({
    required BuildContext context,
    required SelectableRegionState state,
    required String Function() selectedText,
    required Book book,
    required String accessToken,
    required List<Chapter> chapters,
    required Future<String> Function(int chapterIndex) loadChapterText,
    required void Function(int chapterIndex, int charOffset) onJumpToResult,
  }) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () {
            ContextMenuController.removeAny();
            _copy(context, selectedText());
          },
        ),
        ContextMenuButtonItem(
          label: '字典',
          onPressed: () {
            ContextMenuController.removeAny();
            _dictionary(context, selectedText());
          },
        ),
        ContextMenuButtonItem(
          label: '过滤',
          onPressed: () {
            ContextMenuController.removeAny();
            _filter(context, selectedText(), book, accessToken);
          },
        ),
        ContextMenuButtonItem(
          label: '搜索',
          onPressed: () {
            ContextMenuController.removeAny();
            _search(
              context,
              selectedText(),
              book,
              accessToken,
              chapters,
              loadChapterText,
              onJumpToResult,
            );
          },
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 复制

  static Future<void> _copy(BuildContext context, String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) _toast(context, '已复制');
  }

  // ------------------------------------------------------------------ 字典

  static Future<void> _dictionary(BuildContext context, String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;

    try {
      final handled =
          await _dictChannel.invokeMethod<bool>('lookup', {'text': text});
      if (handled == true) return;
    } on MissingPluginException {
      // 桌面 / 测试环境没有这个通道，继续走下面的网页降级
    } catch (_) {
      // 原生侧抛错也降级，不要因为查词典把阅读页搞崩
    }

    if (!context.mounted) return;
    // 降级：打开网页版汉典。选汉典而不是搜索引擎，是因为「字典」的语义
    // 是查词义，搜索页会给一堆无关结果。
    final uri = Uri.parse('https://www.zdic.net/hans/${Uri.encodeComponent(text)}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) _toast(context, '没有可用的词典应用');
    }
  }

  // ------------------------------------------------------------------ 过滤

  /// 弹窗 → 写入「替换净化」。
  static Future<void> _filter(
    BuildContext context,
    String raw,
    Book book,
    String accessToken,
  ) async {
    final selected = raw.trim();
    if (selected.isEmpty) return;

    final result = await showFilterRuleDialog(context, pattern: selected);
    if (result == null) return;

    final pattern = result.pattern.trim();
    if (pattern.isEmpty) {
      if (context.mounted) _toast(context, '要过滤的内容不能为空');
      return;
    }

    final bookName = book.name?.trim() ?? '';
    final rule = ReplaceRule(
      // 名字取「过滤:」+ 内容前 12 字，方便在替换净化列表里认出来
      name: '过滤:${_shorten(pattern)}',
      pattern: pattern,
      replacement: result.replacement,
      // 【替换范围 = 本书名】后端按 scope LIKE '%书名%' 匹配，
      // 所以只对这本书生效，不会污染其它书。
      scope: bookName,
      scopeTitle: false,
      scopeContent: true,
      // 弹窗里没有「正则」开关，按**字面**匹配更安全：
      // 用户输入的 `(` `\` `+` 这类字符不会被当成正则元字符。
      isRegex: false,
      isEnabled: true,
      order: 0,
    );

    try {
      final resp = await ApiService.instance.addReplaceRule(accessToken, rule);
      final ok = resp['isSuccess'] == true || resp['data'] != null;
      if (context.mounted) {
        _toast(context, ok ? '已加入替换净化（范围：本书）' : '添加失败，请稍后再试');
      }
    } catch (e) {
      if (context.mounted) _toast(context, '添加失败：${friendlyError(e)}');
    }
  }

  static String _shorten(String text) {
    final oneLine = text.replaceAll('\n', ' ').trim();
    return oneLine.length <= 12 ? oneLine : '${oneLine.substring(0, 12)}…';
  }

  // ------------------------------------------------------------------ 搜索

  static Future<void> _search(
    BuildContext context,
    String raw,
    Book book,
    String accessToken,
    List<Chapter> chapters,
    Future<String> Function(int chapterIndex) loadChapterText,
    void Function(int chapterIndex, int charOffset) onJumpToResult,
  ) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookTextSearchPage(
          book: book,
          accessToken: accessToken,
          chapters: chapters,
          keyword: keyword,
          loadChapterText: loadChapterText,
          onJumpToResult: onJumpToResult,
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 工具

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

/// 「过滤」弹窗的返回值。
typedef FilterRuleInput = ({String pattern, String replacement});

/// 对齐 3.41 的「过滤」弹窗：
///   标题「请输入要过滤的内容」/ 副标题「请谨慎使用」
///   两个输入框：要过滤的内容（预填选中文字）、替换内容（可空）
///
/// 取消返回 null。
Future<FilterRuleInput?> showFilterRuleDialog(
  BuildContext context, {
  required String pattern,
}) {
  final patternCtrl = TextEditingController(text: pattern);
  final replacementCtrl = TextEditingController();

  return showDialog<FilterRuleInput>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '请输入要过滤的内容',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 6),
            Text(
              '请谨慎使用',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: patternCtrl,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '要过滤的内容',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: replacementCtrl,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '替换内容，可空',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(
              (pattern: patternCtrl.text, replacement: replacementCtrl.text),
            ),
            child: const Text('确定'),
          ),
        ],
      );
    },
  ).whenComplete(() {
    patternCtrl.dispose();
    replacementCtrl.dispose();
  });
}
