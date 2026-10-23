import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/book.dart';
import '../../models/bookmark.dart';
import '../../models/chapter.dart';
import '../../models/reader_launch_args.dart';
import '../../services/api_service.dart';
import '../../services/chapter_cache_export.dart';
import '../../services/error_text.dart';
import '../../services/local_cache_service.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/book_detail_style.dart';

/// 书籍详情页的「目录 / 书签 / 笔记」底部弹层。
///
/// 点章节 / 书签时通过 `Navigator.pop` 返回 [ReaderLaunchArgs]，
/// 由详情页负责打开阅读器 —— 弹层自己不碰阅读状态。
class BookTocSheet extends StatefulWidget {
  const BookTocSheet({
    Key? key,
    required this.book,
    required this.token,
  }) : super(key: key);

  final Book book;
  final String token;

  @override
  State<BookTocSheet> createState() => _BookTocSheetState();
}

class _BookTocSheetState extends State<BookTocSheet> {
  int _tab = 0;
  bool _loading = true;
  bool _refreshing = false;
  bool _ascending = true;
  String? _error;
  String _query = '';

  List<Chapter> _chapters = [];
  List<Bookmark> _bookmarks = [];
  Set<int> _readIndices = {};
  bool _bookmarksLoaded = false;

  final _searchCtl = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String get _bookUrl => widget.book.bookUrl ?? '';
  String get _origin => widget.book.origin ?? '';

  Future<void> _load({bool refresh = false}) async {
    if (widget.token.isEmpty || _bookUrl.isEmpty || _origin.isEmpty) {
      setState(() {
        _loading = false;
        _error = '缺少书籍信息，无法读取目录';
      });
      return;
    }
    setState(() {
      if (refresh) {
        _refreshing = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final chapters = await ApiService.instance.getChapterListNew(
        widget.token,
        _bookUrl,
        _origin,
        bookname: widget.book.name,
        needRefresh: refresh ? 1 : null,
      );
      final read = await _loadReadIndices();
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _readIndices = read;
        _loading = false;
        _refreshing = false;
      });
      _jumpToCurrent();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = '目录加载失败：${friendlyError(e)}';
      });
    }
  }

  Future<Set<int>> _loadReadIndices() async {
    try {
      final raw = await ApiService.instance.getBookread(widget.token, _bookUrl);
      return raw
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _loadBookmarks() async {
    if (_bookmarksLoaded) return;
    _bookmarksLoaded = true;
    try {
      final list =
          await ApiService.instance.getBookmarks(widget.token, _bookUrl);
      if (!mounted) return;
      setState(() {
        _bookmarks = list.map((e) => Bookmark.fromJson(e)).toList();
      });
    } catch (_) {
      _bookmarksLoaded = false;
    }
  }

  void _jumpToCurrent() {
    if (_scrollController.hasClients || _chapters.isEmpty) return;
    final current = widget.book.durChapterIndex ?? 0;
    if (current <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      const rowHeight = 76.0;
      final target = (current - 1).clamp(0, _chapters.length - 1) * rowHeight;
      _scrollController.jumpTo(
        target
            .clamp(0.0, _scrollController.position.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  // ---------------------------------------------------------------- 结构

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.92;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: BookDetailStyle.sheet(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            _buildTopActions(),
            _buildBookHeader(),
            const SizedBox(height: 14),
            _buildTabs(),
            const SizedBox(height: 6),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildTopActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 14, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          PopupMenuButton<String>(
            tooltip: '',
            offset: const Offset(0, 46),
            color: BookDetailStyle.card(context),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            onSelected: (v) {
              if (v == 'refresh') _load(refresh: true);
              if (v == 'export') _exportCached();
            },
            itemBuilder: (_) => [
              _menuItem('refresh', '刷新', Icons.refresh),
              _menuItem('export', '导出', Icons.ios_share),
            ],
            child: _circle(
              icon: Icons.more_vert,
              size: 42,
              iconSize: 22,
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: _circle(icon: Icons.close, size: 42, iconSize: 22),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, String label, IconData icon) {
    final color = BookDetailStyle.text(context);
    return PopupMenuItem<String>(
      value: value,
      height: 56,
      child: Row(
        children: [
          Icon(icon, size: 21, color: color),
          const SizedBox(width: 14),
          Text(label, style: TextStyle(fontSize: 17, color: color)),
        ],
      ),
    );
  }

  Widget _circle({
    required IconData icon,
    double size = 40,
    double iconSize = 20,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: BookDetailStyle.circleButton(context),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, size: iconSize, color: BookDetailStyle.text(context)),
    );
  }

  Widget _buildBookHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(7),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: BookCover(
              url: _displayCover,
              sourceUrl: widget.book.origin,
              width: 62,
              height: 88,
              radius: 5,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.book.name ?? '未知书名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                    color: BookDetailStyle.text(context),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.person_outline,
                      size: 17,
                      color: BookDetailStyle.sub(context),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        widget.book.author ?? '未知作者',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: BookDetailStyle.sub(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    const labels = ['目录', '书签', '笔记'];
    const icons = [Icons.menu_book, Icons.bookmark, Icons.notes];
    final bg = BookDetailStyle.isDark(context)
        ? const Color(0xFF2A2E33)
        : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        height: 46,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _tab = i);
                    if (i == 1) _loadBookmarks();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      color: _tab == i
                          ? BookDetailStyle.accent
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(21),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icons[i],
                          size: 18,
                          color: _tab == i
                              ? Colors.white
                              : BookDetailStyle.sub(context),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          labels[i],
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: _tab == i
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _tab == i
                                ? Colors.white
                                : BookDetailStyle.sub(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_tab == 1) return _buildBookmarks();
    if (_tab == 2) return _buildNotes();
    return _buildToc();
  }

  // ---------------------------------------------------------------- 目录

  Widget _buildToc() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _errorView(_error!);
    }
    final visible = _visibleChapters();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 18, 2),
          child: Row(
            children: [
              Text(
                '共 ${_chapters.length} 章',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: BookDetailStyle.text(context),
                ),
              ),
              const Spacer(),
              if (_refreshing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _ascending = !_ascending),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: BookDetailStyle.isDark(context)
                        ? const Color(0xFF2A2E33)
                        : const Color(0xFFE9EBEF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _ascending ? '正序' : '倒序',
                        style: TextStyle(
                          fontSize: 15,
                          color: BookDetailStyle.text(context),
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: BookDetailStyle.sub(context),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              if (visible.isEmpty)
                Center(
                  child: Text(
                    _query.isEmpty ? '目录为空' : '没有匹配的章节',
                    style: TextStyle(color: BookDetailStyle.sub(context)),
                  ),
                )
              else
                ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(22, 4, 18, 86),
                  itemCount: visible.length,
                  itemBuilder: (_, i) =>
                      _buildChapterRow(visible[i], i),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 10,
                child: _buildSearchField(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<int> _visibleChapters() {
    var indices = List<int>.generate(_chapters.length, (i) => i);
    final query = _query.toLowerCase();
    if (query.isNotEmpty) {
      indices = indices.where((i) {
        final title = (_chapters[i].title ?? '').toLowerCase();
        return title.contains(query);
      }).toList(growable: false);
    }
    if (!_ascending) {
      return indices.reversed.toList(growable: false);
    }
    return indices;
  }

  Widget _buildChapterRow(int index, int position) {
    final chapter = _chapters[index];
    final current = widget.book.durChapterIndex == index;
    final read = _readIndices.contains(index) ||
        (widget.book.durChapterIndex != null &&
            index < widget.book.durChapterIndex!);
    final color = current
        ? BookDetailStyle.accent
        : read
            ? BookDetailStyle.sub(context)
            : BookDetailStyle.text(context);
    final subtitle = _chapterSubtitle(chapter);
    final showCheck = _readIndices.contains(index) || current;
    return InkWell(
      onTap: () => Navigator.pop(
        context,
        ReaderLaunchArgs(book: widget.book, chapterIndex: index),
      ),
      child: SizedBox(
        height: 76,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    chapter.title ?? '第${index + 1}章',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16.5,
                      color: color,
                      fontWeight:
                          current ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: BookDetailStyle.sub(context)
                            .withOpacity(current ? 1 : 0.9),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (showCheck) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.check,
                size: 17,
                color: BookDetailStyle.sub(context).withOpacity(0.45),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _chapterSubtitle(Chapter chapter) {
    final parts = <String>[];
    final time = chapter.lastCheckTime;
    if (time != null && time > 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(time * 1000);
      String two(int v) => v.toString().padLeft(2, '0');
      parts.add('${dt.year}-${two(dt.month)}-${two(dt.day)} '
          '${two(dt.hour)}:${two(dt.minute)}');
    }
    final wc = chapter.wordCount?.trim() ?? '';
    if (wc.isNotEmpty) {
      parts.add(wc.endsWith('字') ? wc : '$wc字');
    }
    return parts.join(' | ');
  }

  Widget _buildSearchField() {
    return Container(
      decoration: BoxDecoration(
        color: BookDetailStyle.card(context),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: TextField(
        controller: _searchCtl,
        onChanged: (v) => setState(() => _query = v.trim()),
        style: TextStyle(
          fontSize: 16,
          color: BookDetailStyle.text(context),
        ),
        decoration: InputDecoration(
          hintText: '搜索标题',
          hintStyle: TextStyle(
            color: BookDetailStyle.sub(context),
            fontSize: 16,
          ),
          prefixIcon: Icon(
            Icons.search,
            color: BookDetailStyle.sub(context),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 书签

  Widget _buildBookmarks() {
    if (_bookmarks.isEmpty) {
      return _emptyView(
        icon: Icons.bookmark_border,
        text: '还没有书签',
        hint: '阅读时点右上角添加书签',
      );
    }
    final list = _bookmarks;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      itemCount: list.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: BookDetailStyle.sub(context).withOpacity(0.15),
      ),
      itemBuilder: (_, i) {
        final mark = list[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            mark.chapterName ?? '未命名书签',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              color: BookDetailStyle.text(context),
            ),
          ),
          subtitle: Text(
            mark.createTime ?? '',
            style: TextStyle(
              fontSize: 13,
              color: BookDetailStyle.sub(context),
            ),
          ),
          onTap: () {
            final index = mark.chapterIndex;
            if (index == null) {
              _toast('这条书签没有章节信息');
              return;
            }
            Navigator.pop(
              context,
              ReaderLaunchArgs(
                book: widget.book,
                chapterIndex: index,
                chapterPosition: mark.chapterPos?.round() ?? 0,
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------- 笔记

  Widget _buildNotes() {
    return _emptyView(
      icon: Icons.notes,
      text: '还没有笔记',
      hint: '笔记功能还在开发中',
    );
  }

  // ---------------------------------------------------------------- 刷新 / 导出

  Future<void> _exportCached() async {
    final url = _bookUrl;
    if (url.isEmpty) return;
    final hash = LocalCacheService.instance.scopedKey(url);
    try {
      final books = await LocalCacheService.instance.listChapterCacheBooks();
      ChapterCacheBook? hit;
      for (final b in books) {
        if (b.hash == hash || b.bookUrl == url) {
          hit = b;
          break;
        }
      }
      if (hit == null) {
        _toast('这本书还没有本地缓存，先读几章再导出');
        return;
      }
      final variant = hit.preferred();
      if (variant == null) {
        _toast('没有可导出的缓存');
        return;
      }
      final chapters =
          await LocalCacheService.instance.readChapterCacheVariant(
        bookHash: hit.hash,
        variant: variant,
      );
      if (chapters.isEmpty) {
        _toast('缓存里没有正文');
        return;
      }
      final text = ChapterCacheExport.buildBookSection(
        bookName: widget.book.name ?? '未知书籍',
        author: widget.book.author,
        chapters: chapters,
        exportedAt:
            ChapterCacheExport.timestampLabel(DateTime.now()),
      );
      await Clipboard.setData(ClipboardData(text: text));
      _toast('已复制 ${chapters.length} 章到剪贴板');
    } catch (e) {
      _toast('导出失败：${friendlyError(e)}');
    }
  }

  // ---------------------------------------------------------------- 工具

  String? get _displayCover {
    final custom = widget.book.customCoverUrl?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    return widget.book.coverUrl;
  }

  Widget _emptyView({
    required IconData icon,
    required String text,
    String? hint,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 46,
            color: BookDetailStyle.sub(context).withOpacity(0.6),
          ),
          const SizedBox(height: 14),
          Text(
            text,
            style: TextStyle(
              fontSize: 16,
              color: BookDetailStyle.text(context),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint,
              style: TextStyle(
                fontSize: 13,
                color: BookDetailStyle.sub(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _errorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: BookDetailStyle.sub(context)),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loading ? null : () => _load(),
              style: FilledButton.styleFrom(
                backgroundColor: BookDetailStyle.accent,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}
