import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/book.dart';
import '../../models/replace_rule.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/app_settings.dart';
import '../../services/chapter_cache_export.dart';
import '../../services/export_file_saver.dart';
import '../../services/local_cache_service.dart';
import '../../services/replace_rule_store.dart';
import '../../services/storage_service.dart';

class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({Key? key}) : super(key: key);

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  int _chapterCacheCount = 5;
  bool _clearing = false;

  // ---- 章节缓存明细 ----
  List<ChapterCacheBook> _cacheBooks = const [];
  bool _loadingCaches = true;

  /// 勾选的书（用 `reader/<哈希>` 里那个哈希做键）。
  final Set<String> _selected = <String>{};

  /// 清理 / 导出进行中，期间禁用底部按钮。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _reloadCaches();
  }

  Future<void> _loadSettings() async {
    final storage = await StorageService.instance;
    if (!mounted) return;
    setState(() {
      _chapterCacheCount = storage.readerChapterCacheCount;
    });
  }

  /// 重新扫一遍本地章节缓存，并顺手把「没书名」的老缓存补上书名。
  Future<void> _reloadCaches() async {
    if (!mounted) return;
    setState(() => _loadingCaches = true);
    var books = const <ChapterCacheBook>[];
    try {
      books = await LocalCacheService.instance.listChapterCacheBooks();
    } catch (_) {
      books = const <ChapterCacheBook>[];
    }
    if (!mounted) return;
    setState(() {
      _cacheBooks = books;
      _loadingCaches = false;
      _selected.removeWhere(
        (hash) => !books.any((b) => b.hash == hash),
      );
    });
    // 补书名是「尽力而为」：拿不到 token / 断网 / 书已不在书架，都只是名字显示成
    // 哈希前缀，不影响后面的清理和导出。
    await _resolveMissingNames();
  }

  /// 老缓存的目录名只有 `md5(bookUrl)`，没有 `meta.json`。
  ///
  /// 拉一次书架，按同样的哈希规则反查书名回填 —— 不然缓存管理页会显示一串
  /// 「未知书籍（a1b2c3d4）」，用户根本认不出是哪本。
  Future<void> _resolveMissingNames() async {
    final pending = _cacheBooks.where((b) => (b.name ?? '').trim().isEmpty);
    if (pending.isEmpty) return;
    final token = context.read<UserProvider>().token;
    if (token == null || token.isEmpty) return;

    List<Book> shelf;
    try {
      shelf = await ApiService.instance.getBookshelfNew(token);
    } catch (_) {
      return;
    }
    if (!mounted || shelf.isEmpty) return;

    final byHash = <String, Book>{};
    for (final book in shelf) {
      final url = book.bookUrl;
      if (url == null || url.isEmpty) continue;
      byHash[LocalCacheService.instance.scopedKey(url)] = book;
    }
    var changed = false;
    for (final entry in _cacheBooks) {
      if ((entry.name ?? '').trim().isNotEmpty) continue;
      final book = byHash[entry.hash];
      if (book == null) continue;
      entry
        ..bookUrl = book.bookUrl
        ..name = book.name
        ..author = book.author
        ..origin = book.origin;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('常规设置')),
      body: ListView(
        // 底部操作栏是浮在上面的，选中时要给它留出高度，否则最后一行被盖住。
        padding: EdgeInsets.only(bottom: _selected.isEmpty ? 24 : 104),
        children: [
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.cached_outlined),
                  title: Text('缓存管理'),
                ),
                ListTile(
                  title: const Text('缓存章节数'),
                  subtitle: Text('当前 $_chapterCacheCount 章'),
                  trailing: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 3, label: Text('3')),
                      ButtonSegment(value: 5, label: Text('5')),
                      ButtonSegment(value: 8, label: Text('8')),
                    ],
                    selected: {_chapterCacheCount},
                    onSelectionChanged: (values) =>
                        _saveChapterCacheCount(values.first),
                  ),
                ),
                ListTile(
                  title: const Text('缓存清理'),
                  subtitle: const Text('清理书架、发现、订阅和阅读章节本地缓存'),
                  trailing: _clearing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  onTap: _clearing ? null : _confirmClearCache,
                ),
                const Divider(height: 1),
                _buildChapterCacheHeader(),
                ..._buildChapterCacheRows(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty ? null : _buildActionBar(),
    );
  }

  // ------------------------------------------------------------ 章节缓存区块

  Widget _buildChapterCacheHeader() {
    final totalBytes =
        _cacheBooks.fold<int>(0, (sum, book) => sum + book.totalBytes);
    final allSelected =
        _cacheBooks.isNotEmpty && _selected.length == _cacheBooks.length;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.storage_outlined, size: 20),
      title: const Text('章节缓存', style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        _loadingCaches
            ? '正在统计…'
            : (_cacheBooks.isEmpty
                ? '还没有读过任何书'
                : '共 ${_cacheBooks.length} 本 · ${ChapterCacheExport.formatBytes(totalBytes)}'),
      ),
      trailing: _cacheBooks.isEmpty
          ? null
          : TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        if (allSelected) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(_cacheBooks.map((b) => b.hash));
                        }
                      }),
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
    );
  }

  List<Widget> _buildChapterCacheRows() {
    if (_loadingCaches) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }
    if (_cacheBooks.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            '读过书之后，这里会按书列出本地缓存的章节，可以单独清理或导出为 txt。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ];
    }

    final settings = AppSettings.instance;
    final currentFingerprint =
        settings.replaceEngine == ReplaceEngineMode.local
            ? ReplaceRuleStore.instance.fingerprint
            : null;

    return [
      for (final book in _cacheBooks)
        _buildChapterCacheRow(book, currentFingerprint),
    ];
  }

  /// 一行 = 一本书。
  ///
  /// 【为什么不用 `CheckboxListTile` + `isThreeLine`】那个组合对副标题行数有
  /// 隐式约束（`isThreeLine` 要求副标题非空、且和 `dense` 一起用容易踩断言），
  /// 这里要显示「章数·体积」和「导出取用哪一份」两行，干脆自己排：
  /// 左边一列文字，右边一个勾选框 —— 也就是用户要的「后面是选择空格」。
  Widget _buildChapterCacheRow(
    ChapterCacheBook book,
    String? currentFingerprint,
  ) {
    final variant = book.preferred(currentFingerprint: currentFingerprint);
    final selected = _selected.contains(book.hash);
    final extras = book.variants.length - 1;

    final line1 = variant == null
        ? '无可用缓存'
        : '${variant.chapterCount} 章 · ${ChapterCacheExport.formatBytes(variant.bytes)}';
    // 把「导出会用到哪一份」写清楚 —— 用户最关心的就是导出来的到底是不是
    // 净化过的正文。
    final line2 = variant == null
        ? ''
        : extras > 0
            ? '导出取用：${variant.flavor.label} · 另有 $extras 份旧缓存'
                '（共 ${ChapterCacheExport.formatBytes(book.totalBytes)}）'
            : '导出取用：${variant.flavor.label}';

    void toggle() {
      if (_busy) return;
      setState(() {
        if (selected) {
          _selected.remove(book.hash);
        } else {
          _selected.add(book.hash);
        }
      });
    }

    final theme = Theme.of(context);
    return InkWell(
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    line1,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (line2.isNotEmpty)
                    Text(
                      line2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Checkbox(
              value: selected,
              onChanged: _busy ? null : (_) => toggle(),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 底部操作

  Widget _buildActionBar() {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已选 ${_selected.length} 本',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _confirmCleanSelected,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清理'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _exportSelected,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('导出'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<ChapterCacheBook> get _selectedBooks =>
      _cacheBooks.where((b) => _selected.contains(b.hash)).toList();

  // -------------------------------------------------------------------- 清理

  Future<void> _confirmCleanSelected() async {
    final books = _selectedBooks;
    if (books.isEmpty) return;
    final totalBytes = books.fold<int>(0, (sum, b) => sum + b.totalBytes);
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('清理章节缓存'),
            content: Text(
              '将删除选中的 ${books.length} 本书的章节缓存，共 ${ChapterCacheExport.formatBytes(totalBytes)}。\n\n'
              '只删本地副本，不影响书架和阅读进度；下次读到这些章节会重新从书源下载。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('清理'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    var deleted = 0;
    for (final book in books) {
      try {
        await LocalCacheService.instance.deleteChapterCacheBook(book.hash);
        deleted++;
      } catch (_) {
        // 单本删失败不打断其余 —— 最后按成功数提示。
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
    });
    await _reloadCaches();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清理 $deleted 本书的章节缓存')),
    );
  }

  // -------------------------------------------------------------------- 导出

  Future<void> _exportSelected() async {
    final books = _selectedBooks;
    if (books.isEmpty) return;

    setState(() => _busy = true);
    try {
      // 本地规则可能在导出时被用到（见下面「现场净化」），先确保手里有一份。
      await ReplaceRuleStore.instance.load();
      if (!mounted) return;

      final settings = AppSettings.instance;
      final rules = ReplaceRuleStore.instance.rules;
      final currentFingerprint =
          settings.replaceEngine == ReplaceEngineMode.local
              ? ReplaceRuleStore.instance.fingerprint
              : null;

      final sections = <String>[];
      var exportedBooks = 0;
      var exportedChapters = 0;
      var purifiedOnTheFly = 0;
      var leftRaw = 0;
      // 真正导出的那本书的展示名。不能直接用 `books.first` —— 用户可能勾了
      // 两本、但其中一本没有可导出内容（被 `continue` 跳过），那样单本文件名
      // 会取到被跳过的那本。
      String? onlyBookName;

      for (final book in books) {
        final variant = book.preferred(currentFingerprint: currentFingerprint);
        if (variant == null) continue;
        final chapters = await LocalCacheService.instance
            .readChapterCacheVariant(bookHash: book.hash, variant: variant);
        if (chapters.isEmpty) continue;

        // 【重点】缓存是「未净化」那一份、而用户当前开着净化时，导出前补跑
        // 一次本地引擎，保证导出的也是净化后的正文。已经净化过的缓存**不会**
        // 再跑一遍（否则 `。` → `。\n` 这类规则会凭空多出一倍空行）。
        // 决策与执行都在 ChapterCacheExport 里（纯 Dart，可被探针打表验证）。
        final prepared = ChapterCacheExport.prepareChapters(
          cached: chapters,
          alreadyPurified: variant.flavor.isPurified,
          canPurifyLocally:
              _canPurifyLocally(book, settings: settings, rules: rules),
          rules: rules,
          bookName: book.name ?? '',
          bookOrigin: book.origin ?? '',
        );
        purifiedOnTheFly += prepared.purifiedOnTheFly;
        leftRaw += prepared.leftRaw;

        sections.add(ChapterCacheExport.buildBookSection(
          bookName: book.displayName,
          author: book.author,
          chapters: prepared.chapters,
          exportedAt: ChapterCacheExport.timestampLabel(DateTime.now()),
        ));
        exportedBooks++;
        exportedChapters += chapters.length;
        if (exportedBooks == 1) onlyBookName = book.displayName;
      }

      if (!mounted) return;
      if (sections.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选中的书没有可导出的缓存内容')),
        );
        return;
      }

      final text = ChapterCacheExport.joinBookSections(sections);
      final single = exportedBooks == 1;
      final suggestedName = single
          ? '${ChapterCacheExport.sanitizeFileName(onlyBookName ?? 'qread_导出')}.txt'
          : 'qread_章节缓存_${exportedBooks}本.txt';

      // 【落盘方式按平台分派】桌面弹「另存为」，Android / iOS / Web 交给系统
      // 分享面板 —— file_selector 的 getSaveLocation() 在这三端根本没实现，
      // 直接调会抛 UnimplementedError。详见 export_delivery.dart。
      final message = await deliverExport(
        bytes: ChapterCacheExport.withUtf8Bom(utf8.encode(text)),
        fileName: suggestedName,
        mimeType: 'text/plain',
        typeGroup: const XTypeGroup(label: 'TXT', extensions: ['txt']),
        shareTitle: suggestedName,
      );
      if (!mounted) return;
      if (message == null) return; // 用户取消了

      final notes = <String>[
        '已导出 $exportedBooks 本 / $exportedChapters 章',
        if (purifiedOnTheFly > 0) '其中 $purifiedOnTheFly 章现场补跑了本地净化',
        if (leftRaw > 0) '$leftRaw 章是未净化正文',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${notes.join('；')}\n$message')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「未净化」的缓存能不能在导出时补净化。
  ///
  /// 真正的判断在 [ChapterCacheExport.canPurifyLocally]（纯 Dart，可测），
  /// 这里只负责把页面手里的 `AppSettings` / 规则表翻译成那几个布尔量。
  bool _canPurifyLocally(
    ChapterCacheBook book, {
    required AppSettings settings,
    required List<ReplaceRule> rules,
  }) {
    return ChapterCacheExport.canPurifyLocally(
      engineIsLocal: settings.replaceEngine == ReplaceEngineMode.local,
      globalUseReplaceRule: settings.useReplaceRule,
      bookUseReplaceRule: book.useReplaceRule,
      ruleCount: rules.length,
    );
  }


  // -------------------------------------------------------------------- 其他

  Future<void> _saveChapterCacheCount(int count) async {
    final storage = await StorageService.instance;
    await storage.setReaderChapterCacheCount(count);
    if (!mounted) return;
    setState(() => _chapterCacheCount = count);
  }

  Future<void> _confirmClearCache() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('清理缓存'),
            content: const Text('将清理本地列表缓存和章节缓存，不会删除账号、设置和书架数据。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('清理'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _clearing = true);
    await LocalCacheService.instance.clearAllCaches();
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('缓存已清理')),
    );
    await _reloadCaches();
  }
}

