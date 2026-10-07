import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/bookshelf_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/error_text.dart';
import '../../services/file_open_service.dart';

/// 「用 Qread 打开一本电子书」时弹出的导入页。
///
/// 【为什么和 FileImportPage 分开】
/// `FileImportPage` 处理的是**书源 JSON 文本** —— 它拿到的是字符串，
/// 判类型、选书源/订阅源、提交 JSON。而 epub / mobi 是二进制，
/// 按 UTF-8 读会直接损坏，只能把**文件路径**交给后端去解析。
/// 两者的输入形态和后续链路都不一样，混在一个页面里只会互相绊住。
///
/// 【上传后为什么直接刷新书架】
/// 后端 `/importBookPreview` 会把书写进用户书架（`Booklist`），
/// 所以这里上传成功就等于「书架多了一本」。当前页面浮在书架之上，
/// 不主动刷新的话用户关掉页面看到的还是旧列表。
class LocalBookImportPage extends StatefulWidget {
  const LocalBookImportPage({Key? key, required this.file}) : super(key: key);

  final OpenedFile file;

  @override
  State<LocalBookImportPage> createState() => _LocalBookImportPageState();
}

class _LocalBookImportPageState extends State<LocalBookImportPage> {
  bool _uploading = false;
  String? _error;
  String? _bookName;
  int? _chapterCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _upload());
  }

  Future<void> _upload() async {
    final path = widget.file.path;
    if (path == null || path.isEmpty) {
      setState(() => _error = '没有拿到文件路径，无法导入');
      return;
    }
    final token = context.read<UserProvider>().token;
    if (token == null) {
      setState(() => _error = '请先登录');
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final resp = await ApiService.instance.importBookPreview(
        token,
        path,
        widget.file.name,
      );
      if (!mounted) return;
      if (resp['isSuccess'] != true) {
        setState(() => _error = friendlyServerMessage(resp['errorMsg'] as String?));
        return;
      }
      final data = resp['data'];
      setState(() {
        _bookName = _pickString(data, 'books', 'name') ?? widget.file.name;
        _chapterCount = _pickChapterCount(data);
      });
      // 书架在后端已经多了一本，这里同步刷一次
      await context
          .read<BookshelfProvider>()
          .loadBookshelf(token, refresh: true);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String? _pickString(Object? data, String mapKey, String field) {
    if (data is Map) {
      final inner = data[mapKey];
      if (inner is Map) {
        final value = inner[field]?.toString();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  int? _pickChapterCount(Object? data) {
    if (data is Map) {
      final chapters = data['chapters'];
      if (chapters is List) return chapters.length;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入本地书籍'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.menu_book_outlined, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.file.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            if (_uploading) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              const Center(child: Text('正在上传并解析，请稍候…')),
            ] else if (_error != null) ...[
              Icon(Icons.error_outline,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _upload, child: const Text('重试')),
            ] else ...[
              Icon(Icons.check_circle_outline,
                  size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                '《${_bookName ?? widget.file.name}》导入成功'
                '${_chapterCount == null ? '' : '，共 $_chapterCount 章'}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('完成'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
