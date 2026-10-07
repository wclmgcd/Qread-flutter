import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/chapter.dart';

/// 一条命中结果。
class BookSearchHit {
  final int chapterIndex;
  final String chapterTitle;

  /// 命中位置在**该章纯文本**里的字符偏移。
  /// 阅读页把它换算成「第几页 + 页内位置」后跳过去。
  final int charOffset;

  /// 命中处的上下文片段（前后各截一段，用于列表展示）。
  final String snippet;

  const BookSearchHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.charOffset,
    required this.snippet,
  });
}

/// 书内全文搜索。
///
/// 【为什么不做成一次请求】
/// 后端没有「整本书搜关键词」的接口 —— 正文是按章缓存的，逐章取才走得通
/// （命中缓存时是内存读，没命中才回源）。所以这里在前端做并发遍历：
/// 4 个 worker 轮流取章，命中就记一条，边搜边出结果。
///
/// 【为什么不复用 ReaderProvider】
/// 阅读页持有的是**当前章节附近**的预取缓存，换书/换章会清空；搜索要的是
/// 全书，两者生命周期不同。所以调用方传进来一个 `loadChapterText` 回调，
/// 由阅读页决定「从哪取正文」（它内部已经接了本地缓存 + 后端缓存）。
class BookTextSearchPage extends StatefulWidget {
  final Book book;
  final String accessToken;
  final List<Chapter> chapters;
  final String keyword;
  final Future<String> Function(int chapterIndex) loadChapterText;

  /// 点中某条结果时回调：章节下标 + 章内字符偏移。
  final void Function(int chapterIndex, int charOffset) onJumpToResult;

  const BookTextSearchPage({
    super.key,
    required this.book,
    required this.accessToken,
    required this.chapters,
    required this.keyword,
    required this.loadChapterText,
    required this.onJumpToResult,
  });

  @override
  State<BookTextSearchPage> createState() => _BookTextSearchPageState();
}

class _BookTextSearchPageState extends State<BookTextSearchPage> {
  late final TextEditingController _keywordCtrl;
  final List<BookSearchHit> _hits = [];

  bool _searching = false;
  bool _cancelled = false;
  int _scanned = 0;
  int _failed = 0;

  @override
  void initState() {
    super.initState();
    _keywordCtrl = TextEditingController(text: widget.keyword);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startSearch();
    });
  }

  @override
  void dispose() {
    _cancelled = true;
    _keywordCtrl.dispose();
    super.dispose();
  }

  Future<void> _startSearch() async {
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty) return;

    setState(() {
      _searching = true;
      _cancelled = false;
      _hits.clear();
      _scanned = 0;
      _failed = 0;
    });

    final total = widget.chapters.length;
    // 并发 4：再多会把后端的章节请求打满（后端本身也有限流），
    // 再少则整本书要等太久。
    const concurrency = 4;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled || !mounted) return;
        final index = next++;
        if (index >= total) return;
        try {
          final text = await widget.loadChapterText(index);
          if (_cancelled || !mounted) return;
          final at = text.indexOf(keyword);
          if (at >= 0) {
            _hits.add(BookSearchHit(
              chapterIndex: index,
              chapterTitle: widget.chapters[index].title ?? '',
              charOffset: at,
              snippet: _snippet(text, at, keyword.length),
            ));
          }
        } catch (_) {
          _failed++;
        }
        _scanned++;
        if (mounted && !_cancelled) setState(() {});
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (!mounted) return;
    setState(() {
      _searching = false;
      // 并发收集的顺序是乱的，按章节顺序排回来
      _hits.sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    });
  }

  String _snippet(String text, int at, int len) {
    final start = (at - 16).clamp(0, text.length);
    final end = (at + len + 28).clamp(0, text.length);
    var s = text.substring(start, end).replaceAll('\n', ' ').trim();
    if (start > 0) s = '…$s';
    if (end < text.length) s = '$s…';
    return s;
  }

  void _openHit(BookSearchHit hit) {
    widget.onJumpToResult(hit.chapterIndex, hit.charOffset);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _keywordCtrl,
          autofocus: false,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _startSearch(),
          decoration: const InputDecoration(
            hintText: '搜索本书内容',
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: _startSearch,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_searching && _hits.isEmpty) {
      return _buildProgress();
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          _searching
              ? '正在搜索…'
              : _scanned == 0
                  ? '输入关键词后开始搜索'
                  : '没有找到「${_keywordCtrl.text.trim()}」',
          style: const TextStyle(color: Colors.black54),
        ),
      );
    }
    return Column(
      children: [
        _buildProgress(),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: _hits.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final hit = _hits[index];
              return ListTile(
                dense: true,
                title: Text(
                  hit.chapterTitle.isEmpty ? '第 ${hit.chapterIndex + 1} 章' : hit.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  hit.snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                onTap: () => _openHit(hit),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    final total = widget.chapters.length;
    final percent = total == 0 ? 0.0 : (_scanned / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _searching
                      ? '搜索中 $_scanned/$total 章，命中 ${_hits.length} 处'
                      : '搜索完成：$_scanned/$total 章，命中 ${_hits.length} 处'
                          '${_failed > 0 ? '（$_failed 章读取失败）' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
              if (_searching)
                TextButton(
                  onPressed: () => setState(() => _cancelled = true),
                  child: const Text('停止'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: percent),
        ],
      ),
    );
  }
}
