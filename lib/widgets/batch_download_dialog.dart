import 'package:flutter/material.dart';

/// 批量下载的执行体：从 [start] 起下载 [count] 章，返回实际新下载的章数。
///
/// [onProgress] 每处理完一章回调一次（驱动进度条）；
/// [isCancelled] 返回 true 时立即停。实现方自己处理单章失败。
typedef BatchDownloadRunner = Future<int> Function(
  int start,
  int count, {
  required void Function(int done) onProgress,
  required bool Function() isCancelled,
});

/// 「批量下载 / 缓存书籍」弹窗 —— 轻阅时光样式。
///
/// 阅读页 ⋮ 菜单和书籍详情页 ⋮ 菜单共用。调用方只需提供章节总数、
/// 当前章下标和真正干活的 [runner]（一般是 ReaderProvider.cacheChapterRange）。
///
/// 流程：选择下载章节（后20/50/100/全部/自定义）→ 带进度的下载弹窗
/// （可取消）→ 结果 toast。
Future<void> showBatchDownloadDialog(
  BuildContext context, {
  required int totalChapters,
  required int currentChapterIndex,
  required BatchDownloadRunner runner,
  void Function(String message)? onToast,
}) async {
  void toast(String message) {
    if (onToast != null) {
      onToast(message);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> run(int count) async {
    final start = currentChapterIndex + 1;
    if (start >= totalChapters || count <= 0) {
      toast('后面没有章节了');
      return;
    }
    final actual = (start + count) > totalChapters ? totalChapters - start : count;

    var done = 0;
    var cancelled = false;
    StateSetter? progressSetState;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          progressSetState = setState;
          return AlertDialog(
            title: const Text('批量下载'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: actual == 0 ? 0 : done / actual,
                ),
                const SizedBox(height: 12),
                Text('正在下载 $done/$actual 章'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => cancelled = true,
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );

    int downloaded = 0;
    try {
      downloaded = await runner(
        start,
        actual,
        onProgress: (d) {
          done = d;
          progressSetState?.call(() {});
        },
        isCancelled: () => cancelled,
      );
    } finally {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    toast(cancelled ? '已取消，新下载 $downloaded 章' : '下载完成，新下载 $downloaded 章');
  }

  Widget row(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 15, color: Color(0xFF222222))),
            ),
            const Icon(Icons.chevron_right,
                size: 20, color: Color(0xFFAAAAAA)),
          ],
        ),
      ),
    );
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      void pick(int count) {
        Navigator.pop(dialogContext);
        run(count);
      }

      return Dialog(
        backgroundColor: Colors.white,
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '选择下载章节',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF222222),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    row('后20章', () => pick(20)),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    row('后50章', () => pick(50)),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    row('后100章', () => pick(100)),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    row('后面全部章节',
                        () => pick(totalChapters - currentChapterIndex - 1)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: row('自定义后多少章', () async {
                  Navigator.pop(dialogContext);
                  final count = await _askDownloadCount(context);
                  if (count != null && count > 0 && context.mounted) {
                    run(count);
                  }
                }),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF222222),
                  minimumSize: const Size(120, 44),
                ),
                child: const Text('取消', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 「自定义后多少章」的数字输入框。
Future<int?> _askDownloadCount(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('自定义后多少章'),
      content: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '输入章节数，如 30',
          isDense: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final n = int.tryParse(controller.text.trim());
            Navigator.pop(ctx, n);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
