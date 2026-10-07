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

    // 【为什么写入前要先查一次已有规则】
    // 后端 `addReplaceRule` 的判重是**精确匹配 name**
    // （`getrulebyname`: `WHERE userid=? AND name=?`），主键又是
    // `Md5(userid + name)` —— 同名必然同 id，没法靠清空 id 绕过判重：
    //   - id 为空 → 走 insert，撞名直接抛 NAME_ERROR（"名字重复"）
    //   - id 非空 → 走 update，但仍会拿 name 查一遍，查到别的 id 就抛
    // 所以「同一段文字再点一次过滤（想改替换内容）」必须**显式带上已有那条的 id**，
    // 否则用户永远只能拿到一句"名字重复"。
    final identity = await _resolveRuleIdentity(accessToken, bookName, pattern);
    final existing = identity.existing;

    final rule = ReplaceRule(
      id: existing?.id,
      name: identity.name,
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
      // 更新时保留原排序，别把用户手动置顶过的规则打回 0
      order: existing?.order ?? 0,
    );

    try {
      final resp = await ApiService.instance.addReplaceRule(accessToken, rule);
      if (!context.mounted) return;
      // 【不要把 errorMsg 吞掉】
      // 后端判重是精确匹配 name，重名时返回 `JsonResponse(false, NAME_ERROR)`，
      // NAME_ERROR = "名字重复"（中文，本来就是给用户看的）。
      // 以前这里只显示「添加失败，请稍后再试」，用户完全不知道该怎么办。
      final ok = resp['isSuccess'] == true;
      _toast(
        context,
        ok
            ? (existing != null ? '已更新本书的过滤规则' : '已加入替换净化（范围：本书）')
            : '添加失败：${friendlyServerMessage(resp['errorMsg']?.toString())}',
      );
    } catch (e) {
      if (context.mounted) _toast(context, '添加失败：${friendlyError(e)}');
    }
  }

  /// 决定这次「过滤」是**更新已有的那条**还是**新增一条**，并给出不撞名的规则名。
  ///
  /// 命中条件：`scope == 本书名` 且 `pattern == 选中内容`。
  /// 用 (scope, pattern) 而不是只看 pattern —— 同一段文字在不同书里是两条独立规则。
  static Future<({ReplaceRule? existing, String name})> _resolveRuleIdentity(
    String accessToken,
    String bookName,
    String pattern,
  ) async {
    final base = '过滤:${_shorten(pattern)}';

    final List<ReplaceRule> rules;
    try {
      rules = await _fetchAllRules(accessToken);
    } catch (_) {
      // 拉列表失败不该阻断主流程：退化成按默认名新增。
      // 万一真撞名，后端会返回 NAME_ERROR，上面会原样透出给用户。
      return (existing: null, name: base);
    }

    final usedNames = <String>{};
    ReplaceRule? existing;
    for (final r in rules) {
      usedNames.add(r.name);
      if (existing == null &&
          r.pattern == pattern &&
          (r.scope?.trim() ?? '') == bookName) {
        existing = r;
      }
    }
    if (existing != null) return (existing: existing, name: existing.name);

    // 名字取「过滤:」+ 内容前 12 字，方便在替换净化列表里认出来。
    // 但 `_shorten` 会截断 —— 不同文字的前 12 字可能一样，所以撞了就加 (2)、(3)…
    var name = base;
    var n = 2;
    while (usedNames.contains(name)) {
      name = '$base ($n)';
      n++;
    }
    return (existing: null, name: name);
  }

  /// 拉全量替换规则。
  ///
  /// 后端按 50 条一页分页：先 `/getReplaceRulesPage` 拿 `{page, md5}`，
  /// 再按 md5 逐页 `/getReplaceRulesNew`（该接口有 60s 缓存，缓存键含 md5，
  /// 而 md5 每次改规则都会刷新，所以这里读到的不会是旧列表）。
  static Future<List<ReplaceRule>> _fetchAllRules(String accessToken) async {
    final pageData = await ApiService.instance.getReplaceRulesPage(accessToken);
    final data = pageData['data'] ?? pageData;
    final md5 = data['md5']?.toString();
    final totalPages = int.tryParse(data['page']?.toString() ?? '1') ?? 1;

    final all = <ReplaceRule>[];
    for (var page = 1; page <= totalPages; page++) {
      final chunk = await ApiService.instance.getReplaceRulesNew(
        accessToken,
        md5: md5,
        page: page,
      );
      if (chunk.isEmpty) break;
      all.addAll(chunk);
    }
    return all;
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
