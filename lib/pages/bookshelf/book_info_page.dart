import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/routes.dart';
import '../../models/book.dart';
import '../../models/book_group.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../login/source_login_page.dart';
import 'book_source_switch_page.dart';

/// 书籍信息页参数
class BookInfoPageArgs {
  const BookInfoPageArgs({required this.book, this.fromBookshelf = true});

  final Book book;

  /// 是否从书架进来的（删除后要回退并刷新书架）
  final bool fromBookshelf;
}

/// 书籍信息页
///
/// 对齐官方 3.41：点击书架里的书籍封面进入本页，展示
/// 封面 / 书名 / 字数标签 / 作者 / 来源 / 类型 / 分组 / 最新章节 / 阅读进度，
/// 底部「删除 / 阅读」，右上角菜单
/// 「更换书源 / 编辑书本 / 书源登录 / 清除缓存 / 书籍变量 / 本地缓存」。
///
/// 【为什么之前点封面没反应】旧实现 `BookCard.onTap` 直接 `pushNamed('/reader')`
/// 进阅读器，根本没有中间的信息页。
class BookInfoPage extends StatefulWidget {
  const BookInfoPage({Key? key, required this.args}) : super(key: key);

  final BookInfoPageArgs args;

  @override
  State<BookInfoPage> createState() => _BookInfoPageState();
}

class _BookInfoPageState extends State<BookInfoPage> {
  Book get _book => widget.args.book;

  bool _busy = false;

  static const _typeLabels = {0: '小说', 1: '有声书', 2: '漫画'};

  String get _token => context.read<UserProvider>().token ?? '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = _book;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('书籍信息'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refreshInfo,
          ),
          PopupMenuButton<String>(
            onSelected: _handleMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'switch', child: Text('更换书源')),
              PopupMenuItem(value: 'edit', child: Text('编辑书本')),
              PopupMenuItem(value: 'login', child: Text('书源登录')),
              PopupMenuItem(value: 'clear_cache', child: Text('清除缓存')),
              PopupMenuItem(value: 'variable', child: Text('书籍变量')),
              PopupMenuItem(value: 'local_cache', child: Text('本地缓存')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              children: [
                Center(child: _buildCover()),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    book.name ?? '未知书名',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildTags(),
                const SizedBox(height: 18),
                _buildInfoRows(),
              ],
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 封面

  Widget _buildCover() {
    final book = _book;
    final url = ApiService.instance
        .getCoverProxyUrl(book.coverUrl, sourceUrl: book.origin);
    const w = 132.0;
    const h = 180.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: w,
        height: h,
        child: url.isEmpty
            ? _coverPlaceholder()
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) => _coverPlaceholder(),
                errorWidget: (_, __, ___) => _coverPlaceholder(),
              ),
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
        color: const Color(0xFFE8E8E8),
        alignment: Alignment.center,
        child: const Icon(Icons.menu_book, size: 40, color: Colors.grey),
      );

  // ---------------------------------------------------------------- 标签

  Widget _buildTags() {
    final book = _book;
    final chips = <String>[];
    final wc = book.wordCount?.trim() ?? '';
    if (wc.isNotEmpty) chips.add(wc);
    // kind 形如 "连载,都市,娱乐明星"，空项要丢掉
    final kind = book.kind?.trim() ?? '';
    if (kind.isNotEmpty) {
      chips.addAll(kind
          .split(RegExp(r'[,，]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in chips)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFFFE9E7),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              c,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE05B57)),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- 信息行

  Widget _buildInfoRows() {
    final book = _book;
    final rows = <Widget>[
      _infoRow(Icons.person_outline, '作者', book.author ?? '未知'),
      _infoRow(Icons.folder_outlined, '来源', book.originName ?? book.origin ?? '未知'),
      _infoRow(
        Icons.format_list_bulleted,
        '类型',
        _typeLabels[book.type ?? 0] ?? '小说',
        trailing: _miniButton('修改', _changeType),
      ),
      _infoRow(
        Icons.grid_view_outlined,
        '分组',
        _groupLabel(book),
        trailing: _miniButton('修改', _changeGroup),
      ),
      _infoRow(
        Icons.schedule_outlined,
        '最新',
        book.latestChapterTitle?.trim().isNotEmpty == true
            ? book.latestChapterTitle!
            : '暂无',
        trailing: _miniButton('目录', _openToc),
      ),
      _infoRow(
        Icons.auto_stories_outlined,
        '进度',
        _progressLabel(book),
      ),
    ];
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 32),
          rows[i],
        ],
      ],
    );
  }

  String _groupLabel(Book book) {
    final groups = context.watch<BookshelfProvider>().groups;
    for (final BookGroup g in groups) {
      if (g.groupId != null && g.groupId == book.group) {
        return g.groupName ?? '全部';
      }
    }
    if (book.group == null || book.group == 0) return '全部';
    return '分组${book.group}';
  }

  String _progressLabel(Book book) {
    final t = book.durChapterTitle?.trim() ?? '';
    if (t.isEmpty) return '未开始';
    final idx = book.durChapterIndex;
    return idx == null ? t : '第${idx + 1}章 $t';
  }

  Widget _infoRow(IconData icon, String label, String value,
      {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey.shade600),
          const SizedBox(width: 12),
          SizedBox(
            width: 42,
            child: Text(
              label,
              style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _miniButton(String text, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFFFE9E7),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: Color(0xFFE05B57)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 底部

  Widget _buildBottomBar() {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _deleteBook,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE05B57),
                  side: const BorderSide(color: Color(0xFFE05B57)),
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
                child: const Text('删除'),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: FilledButton(
                onPressed: _openReader,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE05B57),
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
                child: Text(
                  '阅读',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 行为

  Future<void> _handleMenu(String action) async {
    switch (action) {
      case 'switch':
        await _changeSource();
        break;
      case 'edit':
        await _editBook();
        break;
      case 'login':
        await _sourceLogin();
        break;
      case 'clear_cache':
        await _clearCache();
        break;
      case 'variable':
        await _editVariable();
        break;
      case 'local_cache':
        await _showLocalCache();
        break;
    }
  }

  void _openReader() {
    Navigator.pushNamed(context, AppRoutes.reader, arguments: _book);
  }

  void _openToc() {
    // 项目里没有独立的目录页，阅读器本身就带目录面板，
    // 直接进阅读器再让用户点目录，是当前最接近官方的做法。
    Navigator.pushNamed(context, AppRoutes.reader, arguments: _book);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 从后端重新拉一次书籍信息（补齐字数/标签/最新章节等）
  Future<void> _refreshInfo() async {
    final bookUrl = _book.bookUrl;
    if (bookUrl == null || bookUrl.isEmpty) {
      _toast('这本书没有 bookUrl，无法刷新');
      return;
    }
    setState(() => _busy = true);
    try {
      final resp = await ApiService.instance.getBookInfoByUrl(_token, bookUrl);
      final data = resp['data'];
      if (data is Map) {
        final fresh = Book.fromJson(Map<String, dynamic>.from(data));
        setState(() {
          _copyInto(_book, fresh);
        });
        _toast('已刷新');
      } else {
        _toast('刷新失败：${resp['errorMsg'] ?? '返回为空'}');
      }
    } catch (e) {
      _toast('刷新失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用后端返回的新数据覆盖本地 Book 对象（Book 字段是可变的设计）
  void _copyInto(Book dst, Book src) {
    dst.name = src.name ?? dst.name;
    dst.author = src.author ?? dst.author;
    dst.coverUrl = src.coverUrl ?? dst.coverUrl;
    dst.intro = src.intro ?? dst.intro;
    dst.kind = src.kind ?? dst.kind;
    dst.wordCount = src.wordCount ?? dst.wordCount;
    dst.latestChapterTitle = src.latestChapterTitle ?? dst.latestChapterTitle;
    dst.latestChapterTime = src.latestChapterTime ?? dst.latestChapterTime;
    dst.totalChapterNum = src.totalChapterNum ?? dst.totalChapterNum;
    dst.lastCheckTime = src.lastCheckTime ?? dst.lastCheckTime;
    dst.durChapterTitle = src.durChapterTitle ?? dst.durChapterTitle;
    dst.durChapterIndex = src.durChapterIndex ?? dst.durChapterIndex;
    dst.durChapterTime = src.durChapterTime ?? dst.durChapterTime;
  }

  Future<void> _changeSource() async {
    final origin = _book.origin;
    final bookUrl = _book.bookUrl;
    if (origin == null || origin.isEmpty || bookUrl == null || bookUrl.isEmpty) {
      _toast('缺少书源或书籍地址，无法换源');
      return;
    }
    final changed = await Navigator.pushNamed(
      context,
      AppRoutes.bookSourceSwitch,
      arguments: BookSourceSwitchArgs(book: _book),
    );
    if (changed == true) {
      await _refreshInfo();
      if (mounted) context.read<BookshelfProvider>().applySort();
    }
  }

  Future<void> _editBook() async {
    final nameCtl = TextEditingController(text: _book.name ?? '');
    final authorCtl = TextEditingController(text: _book.author ?? '');
    final coverCtl = TextEditingController(text: _book.customCoverUrl ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑书本'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: '书名'),
              ),
              TextField(
                controller: authorCtl,
                decoration: const InputDecoration(labelText: '作者'),
              ),
              TextField(
                controller: coverCtl,
                decoration: const InputDecoration(
                  labelText: '自定义封面地址',
                  hintText: '留空则用书源自带的封面',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _book.name = nameCtl.text.trim();
      _book.author = authorCtl.text.trim();
      final c = coverCtl.text.trim();
      _book.customCoverUrl = c.isEmpty ? null : c;
    });
    await _saveBookToServer();
  }

  Future<void> _saveBookToServer() async {
    try {
      await ApiService.instance.saveBook(_token, _book);
      if (mounted) context.read<BookshelfProvider>().applySort();
      _toast('已保存');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _sourceLogin() async {
    final origin = _book.origin;
    if (origin == null || origin.isEmpty) {
      _toast('这本书没有书源信息');
      return;
    }
    Navigator.pushNamed(
      context,
      AppRoutes.sourceLogin,
      arguments: SourceLoginPageArgs(
        sourceUrl: origin,
        sourceName: _book.originName ?? origin,
        type: 'bookSource',
      ),
    );
  }

  /// 清除这本书在服务器上的缓存
  Future<void> _clearCache() async {
    setState(() => _busy = true);
    try {
      final list = await ApiService.instance.getCanCacheList(_token);
      final name = _book.name ?? '';
      Map<String, dynamic>? hit;
      for (final e in list) {
        if ((e['name']?.toString() ?? '') == name ||
            (e['bookUrl']?.toString() ?? '') == (_book.bookUrl ?? '')) {
          hit = e;
          break;
        }
      }
      if (hit == null) {
        _toast('这本书没有缓存');
        return;
      }
      final id = hit['id']?.toString();
      if (id == null || id.isEmpty) {
        _toast('缓存条目缺少 id，无法删除');
        return;
      }
      await ApiService.instance.delCache(_token, id);
      _toast('已清除缓存');
    } catch (e) {
      _toast('清除缓存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 编辑「书籍变量」（书源里 `{{...}}` 用到的自定义变量）
  Future<void> _editVariable() async {
    final ctl = TextEditingController(text: _prettyJson(_book.variable));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('书籍变量'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctl,
            maxLines: 10,
            minLines: 5,
            decoration: const InputDecoration(
              hintText: '{"key":"value"}',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final text = ctl.text.trim();
    if (text.isNotEmpty) {
      try {
        jsonDecode(text);
      } catch (_) {
        _toast('不是合法的 JSON');
        return;
      }
    }
    setState(() => _book.variable = text.isEmpty ? null : text);
    await _saveBookToServer();
  }

  String _prettyJson(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
    } catch (_) {
      return s;
    }
  }

  /// 服务器上的本地缓存列表
  Future<void> _showLocalCache() async {
    setState(() => _busy = true);
    List<Map<String, dynamic>> list = [];
    try {
      list = await ApiService.instance.getCanCacheList(_token);
    } catch (e) {
      _toast('读取缓存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('本地缓存（${list.length}）'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: list.isEmpty
                ? const Center(child: Text('暂无缓存'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final e = list[i];
                      final num = e['num']?.toString() ?? '0';
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          e['name']?.toString() ?? '未知',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('$num 章'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final id = e['id']?.toString();
                            if (id == null || id.isEmpty) return;
                            try {
                              await ApiService.instance.delCache(_token, id);
                              setLocal(() => list.removeAt(i));
                            } catch (err) {
                              _toast('删除失败：$err');
                            }
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeType() async {
    final picked = await _pickFromMap<int>(
      title: '修改类型',
      items: _typeLabels,
      current: _book.type ?? 0,
    );
    if (picked == null) return;
    final bookUrl = _book.bookUrl;
    if (bookUrl == null || bookUrl.isEmpty) {
      _toast('缺少书籍地址');
      return;
    }
    try {
      await ApiService.instance.changeBookType(_token, bookUrl, picked);
      setState(() => _book.type = picked);
      _toast('已修改');
    } catch (e) {
      _toast('修改失败：$e');
    }
  }

  Future<void> _changeGroup() async {
    final groups = context.read<BookshelfProvider>().groups;
    final map = <int, String>{0: '全部'};
    for (final BookGroup g in groups) {
      if (g.groupId != null) map[g.groupId!] = g.groupName ?? '分组${g.groupId}';
    }
    final picked = await _pickFromMap<int>(
      title: '设置分组',
      items: map,
      current: _book.group ?? 0,
    );
    if (picked == null) return;
    final bookUrl = _book.bookUrl;
    if (bookUrl == null || bookUrl.isEmpty) {
      _toast('缺少书籍地址');
      return;
    }
    try {
      // 后端 /setgroup 收的是分组**名字** + 书籍 url
      await ApiService.instance
          .setgroup(_token, name: map[picked], url: bookUrl);
      setState(() => _book.group = picked);
      if (mounted) context.read<BookshelfProvider>().applySort();
      _toast('已修改');
    } catch (e) {
      _toast('修改失败：$e');
    }
  }

  Future<T?> _pickFromMap<T>({
    required String title,
    required Map<T, String> items,
    required T current,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            for (final e in items.entries)
              ListTile(
                title: Text(e.value),
                trailing: e.key == current
                    ? const Icon(Icons.check, color: Color(0xFFE05B57))
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteBook() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定把《${_book.name ?? ''}》移出书架吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ApiService.instance.deleteBook(_token, _book);
      if (!mounted) return;
      final provider = context.read<BookshelfProvider>();
      provider.removeBookLocally(_book);
      _toast('已删除');
      if (widget.args.fromBookshelf) Navigator.of(context).pop();
    } catch (e) {
      _toast('删除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
