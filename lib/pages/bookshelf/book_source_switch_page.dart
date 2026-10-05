import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/search_result.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/app_settings.dart';

/// 换源页参数
class BookSourceSwitchArgs {
  const BookSourceSwitchArgs({required this.book});

  final Book book;
}

/// 换源
///
/// 【为什么之前是「换源搜索入口待接入」】旧实现点「换源」只弹了个
/// SnackBar 占位。后端其实一直有 `/setBookSource`（ReadController），
/// 只是客户端没接。
///
/// 流程（和官方一致）：
///   1. 用当前书的书名，在**所有已启用书源**上并行搜索；
///   2. 过滤掉当前来源自己，列出候选（书名/作者/来源/最新章节/字数）；
///   3. 选中后调 `/setBookSource` 把这本书切到新来源；
///   4. 返回 true，让调用方刷新书籍信息 / 书架。
class BookSourceSwitchPage extends StatefulWidget {
  const BookSourceSwitchPage({Key? key, required this.args}) : super(key: key);

  final BookSourceSwitchArgs args;

  @override
  State<BookSourceSwitchPage> createState() => _BookSourceSwitchPageState();
}

class _BookSourceSwitchPageState extends State<BookSourceSwitchPage> {
  final _keywordCtrl = TextEditingController();

  List<BookSource> _sources = [];
  List<SearchResult> _results = [];
  bool _loading = true;
  bool _switching = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  Book get _book => widget.args.book;

  @override
  void initState() {
    super.initState();
    _keywordCtrl.text = _book.name ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  String get _token => context.read<UserProvider>().token ?? '';

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
      _done = 0;
    });
    try {
      if (_sources.isEmpty) {
        _sources = await ApiService.instance.getBookSources(_token);
      }
      // 只搜「已启用」且带搜索地址的源；当前来源自己不用搜（换源换的是别的源）
      final enabled = _sources.where((s) {
        if (s.enabled == false) return false;
        if (s.bookSourceUrl == null || s.bookSourceUrl!.isEmpty) return false;
        if (s.bookSourceUrl == _book.origin) return false;
        return true;
      }).toList();
      if (enabled.isEmpty) {
        setState(() {
          _loading = false;
          _error = '没有其它可用的书源';
        });
        return;
      }
      // 搜索线程数来自「阅读偏好 → 其他设置 → 搜索线程」
      final maxConcurrent =
          AppSettings.instance.searchThreadCount.clamp(1, 32);
      final targets = enabled.take(maxConcurrent * 2).toList();
      setState(() => _total = targets.length);

      final keyword = _keywordCtrl.text.trim();
      final merged = <String, SearchResult>{};
      // 分批并发，避免一次性打爆后端
      for (var i = 0; i < targets.length; i += maxConcurrent) {
        final batch = targets.skip(i).take(maxConcurrent);
        await Future.wait(batch.map((s) async {
          try {
            final list = await ApiService.instance.searchBook(
              _token,
              keyword,
              bookSourceUrl: s.bookSourceUrl,
            );
            return list;
          } catch (_) {
            return <SearchResult>[];
          }
        })).then((lists) {
          for (final list in lists) {
            for (final r in list) {
              final key = '${r.name}|${r.author}';
              // 只保留同名同作者（或同作者）的候选，避免搜出一堆无关书
              if (!_looksSameBook(r)) continue;
              merged.putIfAbsent(key, () => r);
            }
          }
          if (mounted) {
            setState(() {
              _done += batch.length;
              _results = merged.values.toList();
            });
          }
        });
      }
      if (mounted) {
        setState(() {
          _loading = false;
          if (_results.isEmpty) _error = '没有找到其它来源的同名书籍';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '搜索失败：$e';
        });
      }
    }
  }

  /// 候选是否「像同一本书」：书名相同，或作者相同
  bool _looksSameBook(SearchResult r) {
    final a = _norm(_book.name);
    final b = _norm(r.name);
    if (a.isNotEmpty && b.isNotEmpty && a == b) return true;
    final aa = _norm(_book.author);
    final ba = _norm(r.author);
    return aa.isNotEmpty && aa == ba && b.contains(a);
  }

  String _norm(String? s) =>
      (s ?? '').replaceAll(RegExp(r'[\s\u3000]'), '').trim();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('换源'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '重新搜索',
            icon: const Icon(Icons.refresh),
            onPressed: _switching ? null : _start,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              controller: _keywordCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _start(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索书名',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward, size: 20),
                  onPressed: _start,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading || _switching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _switching ? '正在换源…' : '正在搜索其它书源 $_done/$_total',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    if (_error != null && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _start, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('没有候选来源'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '当前来源：${_book.originName ?? _book.origin ?? '未知'}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
              Text(
                '共 ${_results.length} 个候选',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: _results.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
            itemBuilder: (_, i) => _buildTile(_results[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildTile(SearchResult r) {
    final cover = ApiService.instance
        .getCoverProxyUrl(r.coverUrl, sourceUrl: r.origin);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 52,
          height: 70,
          child: cover.isEmpty
              ? Container(color: const Color(0xFFE8E8E8))
              : CachedNetworkImage(
                  imageUrl: cover,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) =>
                      Container(color: const Color(0xFFE8E8E8)),
                ),
        ),
      ),
      title: Text(
        r.name ?? '未知',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 3),
          Text(
            '${r.author ?? '未知'} · ${r.wordCount ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 2),
          Text(
            '来源：${r.originName ?? r.origin ?? '未知'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          if ((r.latestChapterTitle ?? '').isNotEmpty)
            Text(
              '最新：${r.latestChapterTitle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
        ],
      ),
      onTap: () => _confirmSwitch(r),
    );
  }

  Future<void> _confirmSwitch(SearchResult r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更换书源'),
        content: Text(
          '把《${_book.name ?? ''}》切换到\n'
          '「${r.originName ?? r.origin ?? '未知来源'}」？\n\n'
          '阅读进度会保留，但缓存需要重新加载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _doSwitch(r);
  }

  Future<void> _doSwitch(SearchResult r) async {
    final bookUrl = _book.bookUrl;
    final newUrl = r.bookUrl;
    final newSource = r.origin;
    if (bookUrl == null || bookUrl.isEmpty) {
      _toast('这本书缺少 bookUrl，无法换源');
      return;
    }
    if (newUrl == null || newUrl.isEmpty || newSource == null) {
      _toast('候选缺少 bookUrl / 书源地址');
      return;
    }
    setState(() => _switching = true);
    try {
      final resp = await ApiService.instance.setBookSource(
        _token,
        bookUrl: bookUrl,
        newUrl: newUrl,
        bookSourceUrl: newSource,
      );
      if (!mounted) return;
      final ok = resp['isSuccess'] == true || resp['data'] != null;
      if (!ok) {
        _toast('换源失败：${resp['errorMsg'] ?? '未知错误'}');
        return;
      }
      // 后端会返回换源后的书，顺手把本地对象更新掉
      final data = resp['data'];
      if (data is Map) {
        final fresh = Book.fromJson(Map<String, dynamic>.from(data));
        _book.origin = fresh.origin ?? _book.origin;
        _book.originName = fresh.originName ?? _book.originName;
        _book.bookUrl = fresh.bookUrl ?? _book.bookUrl;
        _book.tocUrl = fresh.tocUrl ?? _book.tocUrl;
        _book.latestChapterTitle =
            fresh.latestChapterTitle ?? _book.latestChapterTitle;
        _book.totalChapterNum = fresh.totalChapterNum ?? _book.totalChapterNum;
      } else {
        _book.origin = newSource;
        _book.originName = r.originName ?? newSource;
        _book.bookUrl = newUrl;
      }
      if (!mounted) return;
      _toast('已换源到「${_book.originName ?? newSource}」');
      Navigator.of(context).pop(true);
    } catch (e) {
      _toast('换源失败：$e');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}
