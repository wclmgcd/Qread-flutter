import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config/routes.dart';
import '../../models/book.dart';
import '../../models/book_group.dart';
import '../../models/reader_launch_args.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/book_update_prefs.dart';
import '../../services/error_text.dart';
import '../../services/local_cache_service.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/book_detail_style.dart';
import '../login/source_login_page.dart';
import '../search/search_page.dart';
import 'book_edit_page.dart';
import 'book_source_switch_page.dart';
import 'book_toc_sheet.dart';

/// 书籍信息页参数
class BookInfoPageArgs {
  const BookInfoPageArgs({required this.book, this.fromBookshelf = true});

  final Book book;

  /// 是否从书架进来的（删除后要回退并刷新书架）
  final bool fromBookshelf;
}

/// 书籍详情页 —— 视觉对齐轻阅时光。
///
/// 顶部渐变背景 + 圆形按钮，封面/书名/作者/标签，四宫格快捷操作，
/// 信息卡与简介卡，右下角悬浮「阅读」；目录走 [BookTocSheet] 弹层。
class BookInfoPage extends StatefulWidget {
  const BookInfoPage({Key? key, required this.args}) : super(key: key);

  final BookInfoPageArgs args;

  @override
  State<BookInfoPage> createState() => _BookInfoPageState();
}

class _BookInfoPageState extends State<BookInfoPage> {
  Book get _book => widget.args.book;

  bool _busy = false;
  bool _updateDisabled = false;

  static const _typeLabels = {0: '小说', 1: '有声书', 2: '漫画'};

  String get _token => context.read<UserProvider>().token ?? '';

  bool get _inShelf => widget.args.fromBookshelf;

  @override
  void initState() {
    super.initState();
    _loadUpdateState();
  }

  Future<void> _loadUpdateState() async {
    final url = _book.bookUrl ?? '';
    if (url.isEmpty) return;
    final disabled = await BookUpdatePrefs.isDisabled(url);
    if (!mounted) return;
    setState(() => _updateDisabled = disabled);
  }

  // ---------------------------------------------------------------- 结构

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: BookDetailStyle.background(context),
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 110),
                    children: [
                      const SizedBox(height: 6),
                      Center(child: _buildCover()),
                      const SizedBox(height: 18),
                      _buildTitle(),
                      const SizedBox(height: 16),
                      _buildChips(),
                      const SizedBox(height: 16),
                      _buildQuickActions(),
                      const SizedBox(height: 14),
                      _buildInfoCard(),
                      const SizedBox(height: 14),
                      _buildIntroCard(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 20,
            bottom: bottomInset + 22,
            child: _buildReadPill(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: 58,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            '书籍信息',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: BookDetailStyle.text(context),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: _circle(icon: Icons.arrow_back),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _busy ? null : _refreshInfo,
                  child: _circle(icon: Icons.refresh),
                ),
                const SizedBox(width: 10),
                PopupMenuButton<String>(
                  tooltip: '',
                  offset: const Offset(0, 48),
                  color: BookDetailStyle.card(context),
                  constraints:
                      const BoxConstraints(minWidth: 210, maxWidth: 260),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  onSelected: _handleMenu,
                  itemBuilder: (_) => _menuEntries(),
                  child: _circle(icon: Icons.more_vert),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circle({required IconData icon}) {
    return Container(
      width: 42,
      height: 42,
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
      child: Icon(icon, size: 22, color: BookDetailStyle.text(context)),
    );
  }

  Widget _buildCover() {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.13),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: BookCover(
        url: _displayCover,
        sourceUrl: _book.origin,
        width: 132,
        height: 180,
        radius: 6,
      ),
    );
  }

  Widget _buildTitle() {
    final dark = BookDetailStyle.isDark(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            _book.name ?? '未知书名',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: BookDetailStyle.text(context),
            ),
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _authorSearchable ? _searchByAuthor : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 2),
            child: Text(
              _book.author ?? '未知作者',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: BookDetailStyle.sub(context),
                decoration: _authorSearchable
                    ? TextDecoration.underline
                    : TextDecoration.none,
                decorationColor: (dark ? Colors.white : Colors.black)
                    .withOpacity(0.28),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChips() {
    final chips = <Widget>[];
    final origin = (_book.originName ?? '').trim();
    if (origin.isNotEmpty) {
      chips.add(_chip(origin, icon: Icons.signal_cellular_alt));
    }
    final kind = _book.kind?.trim() ?? '';
    if (kind.isNotEmpty) {
      for (final token in kind
          .split(RegExp(r'[,，]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)) {
        chips.add(_chip(token));
      }
    }
    final wc = _book.wordCount?.trim() ?? '';
    if (wc.isNotEmpty) chips.add(_chip(wc));
    if (chips.isEmpty) return const SizedBox(height: 0);
    return SizedBox(
      height: 42,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(children: chips),
      ),
    );
  }

  Widget _chip(String text, {IconData? icon}) {
    return Container(
      height: 42,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: BookDetailStyle.chip,
        borderRadius: BorderRadius.circular(21),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: const TextStyle(
              fontSize: 15,
              color: Colors.white,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 快捷操作

  Widget _buildQuickActions() {
    final actions = <_QuickAction>[
      if (_inShelf)
        _QuickAction(
          icon: _updateDisabled
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          label: _updateDisabled ? '开启更新' : '关闭更新',
          onTap: _toggleUpdate,
        )
      else
        _QuickAction(
          icon: Icons.library_add_outlined,
          label: '加入书架',
          onTap: _addToBookshelf,
        ),
      if (_inShelf)
        _QuickAction(
          icon: Icons.swap_horiz,
          label: '更换书源',
          onTap: _changeSource,
        ),
      _QuickAction(
        icon: Icons.history,
        label: '阅读记录',
        onTap: _showReadHistory,
      ),
      if (_inShelf)
        _QuickAction(
          icon: Icons.delete_outline,
          label: '删除书本',
          onTap: _deleteBook,
          danger: true,
        )
      else
        _QuickAction(
          icon: Icons.menu_book_outlined,
          label: '目录',
          onTap: _openToc,
        ),
    ];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 4),
      decoration: BoxDecoration(
        color: BookDetailStyle.card(context),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          for (final action in actions)
            Expanded(child: _quickActionTile(action)),
        ],
      ),
    );
  }

  Widget _quickActionTile(_QuickAction action) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: _busy ? null : action.onTap,
      child: Column(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: action.danger
                  ? BookDetailStyle.dangerSoft
                  : BookDetailStyle.soft(context),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(
              action.icon,
              size: 26,
              color: action.danger
                  ? BookDetailStyle.danger
                  : BookDetailStyle.accent,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14.5,
              color: action.danger
                  ? BookDetailStyle.danger
                  : BookDetailStyle.accent,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 信息卡

  Widget _buildInfoCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      decoration: BoxDecoration(
        color: BookDetailStyle.card(context),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          _infoRow(
            icon: Icons.format_list_bulleted,
            label: '类型',
            value: _typeLabels[_book.type ?? 0] ?? '小说',
            action: _pill('修改', _changeType),
          ),
          _infoRow(
            icon: Icons.grid_view_outlined,
            label: '分组',
            value: _groupLabel(_book),
            action: _pill('修改', _changeGroup),
          ),
          _infoRow(
            icon: Icons.history,
            label: '最新',
            value: _latestLabel(_book),
            action: _pill('目录', _openToc),
          ),
          _infoRow(
            icon: Icons.menu_book_outlined,
            label: '进度',
            value: _progressLabel(_book),
          ),
        ],
      ),
    );
  }

  Widget _infoRow({
    required IconData icon,
    required String label,
    required String value,
    Widget? action,
  }) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: BookDetailStyle.soft(context),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 19, color: BookDetailStyle.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$label：$value'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                color: BookDetailStyle.text(context),
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 8),
            action,
          ],
        ],
      ),
    );
  }

  Widget _pill(String text, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: _busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: BookDetailStyle.soft(context),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14.5,
            color: BookDetailStyle.accent,
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 简介卡

  Widget _buildIntroCard() {
    final intro = _book.customIntro?.trim().isNotEmpty == true
        ? _book.customIntro!.trim()
        : (_book.intro?.trim() ?? '');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        color: BookDetailStyle.card(context),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.description,
                size: 21,
                color: BookDetailStyle.accent,
              ),
              const SizedBox(width: 8),
              Text(
                '简介',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: BookDetailStyle.text(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            intro.isEmpty ? '暂无简介' : intro,
            style: TextStyle(
              fontSize: 15.5,
              height: 1.8,
              color: intro.isEmpty
                  ? BookDetailStyle.sub(context)
                  : BookDetailStyle.text(context),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 阅读按钮

  Widget _buildReadPill() {
    return GestureDetector(
      onTap: _openReader,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF3FB8FF), BookDetailStyle.accentDeep],
          ),
          borderRadius: BorderRadius.circular(27),
          boxShadow: [
            BoxShadow(
              color: BookDetailStyle.accent.withOpacity(0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book, size: 20, color: Colors.white),
            SizedBox(width: 8),
            Text(
              '阅读',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 菜单

  List<PopupMenuEntry<String>> _menuEntries() {
    final entries = <(String, String)>[
      if (!_inShelf) ('add_shelf', '加入书架'),
      if (_inShelf) ('switch', '更换书源'),
      if (_inShelf) ('toggle_update', _updateDisabled ? '开启更新' : '关闭更新'),
      if (_inShelf) ('edit', '编辑书本'),
      ('login', '书源登录'),
      if (_inShelf) ('clear_cache', '清除缓存'),
      if (_inShelf) ('variable', '书籍变量'),
      ('source_url', '书源地址'),
      ('book_url', '书籍地址'),
      if (_inShelf) ('cache_book', '缓存书本'),
    ];
    final items = <PopupMenuEntry<String>>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      items.add(
        PopupMenuItem<String>(
          value: entry.$1,
          height: 58,
          child: Text(
            entry.$2,
            style: TextStyle(
              fontSize: 17,
              color: BookDetailStyle.text(context),
            ),
          ),
        ),
      );
      if (i != entries.length - 1) {
        items.add(const PopupMenuDivider(height: 1));
      }
    }
    return items;
  }

  Future<void> _handleMenu(String action) async {
    switch (action) {
      case 'add_shelf':
        await _addToBookshelf();
        break;
      case 'switch':
        await _changeSource();
        break;
      case 'toggle_update':
        await _toggleUpdate();
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
      case 'source_url':
        await _showText('书源地址', _book.origin ?? '');
        break;
      case 'book_url':
        await _showText('书籍地址', _book.bookUrl ?? '');
        break;
      case 'cache_book':
        await _cacheBook();
        break;
    }
  }

  // -------------------------------------------------------------- 标签文案

  String _displayCover {
    final custom = _book.customCoverUrl?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    return _book.coverUrl ?? '';
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

  String _latestLabel(Book book) {
    final t = book.latestChapterTitle?.trim() ?? '';
    return t.isEmpty ? '暂无' : t;
  }

  String _progressLabel(Book book) {
    final t = book.durChapterTitle?.trim() ?? '';
    return t.isEmpty ? '未开始' : t;
  }

  bool get _authorSearchable {
    final a = _book.author?.trim() ?? '';
    return a.isNotEmpty && a != '未知';
  }

  // -------------------------------------------------------------- 动作

  void _openReader() {
    Navigator.pushNamed(context, AppRoutes.reader, arguments: _book);
  }

  Future<void> _openToc() async {
    final token = _token;
    if (token.isEmpty) {
      _toast('请先登录');
      return;
    }
    final args = await showModalBottomSheet<ReaderLaunchArgs>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BookTocSheet(book: _book, token: token),
    );
    if (args == null || !mounted) return;
    await Navigator.pushNamed(context, AppRoutes.reader, arguments: args);
    if (mounted) setState(() {});
  }

  Future<void> _toggleUpdate() async {
    final url = _book.bookUrl ?? '';
    if (url.isEmpty) {
      _toast('缺少书籍地址');
      return;
    }
    await BookUpdatePrefs.setDisabled(url, !_updateDisabled);
    if (!mounted) return;
    setState(() => _updateDisabled = !_updateDisabled);
    _toast(_updateDisabled ? '已关闭更新' : '已开启更新');
  }

  Future<void> _showReadHistory() async {
    final token = _token;
    final url = _book.bookUrl ?? '';
    if (token.isEmpty || url.isEmpty) {
      _toast('请先登录');
      return;
    }
    var count = 0;
    try {
      final raw = await ApiService.instance.getBookread(token, url);
      count = raw
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .length;
    } catch (e) {
      _toast('读取阅读记录失败：${friendlyError(e)}');
      return;
    }
    if (!mounted) return;
    final goOn = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('阅读记录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已读 $count 章'),
            const SizedBox(height: 10),
            Text('当前进度：${_progressLabel(_book)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('关闭'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BookDetailStyle.accent,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续阅读'),
          ),
        ],
      ),
    );
    if (goOn == true && mounted) _openReader();
  }

  /// 加入书架（从搜索 / 发现页进来时）
  Future<void> _addToBookshelf() async {
    if (_token.isEmpty) {
      _toast('请先登录');
      return;
    }
    setState(() => _busy = true);
    try {
      await ApiService.instance.saveBook(_token, _book);
      if (!mounted) return;
      await context
          .read<BookshelfProvider>()
          .loadBookshelf(_token, refresh: true);
      _toast('已加入书架');
      Navigator.pop(context, true);
    } catch (e) {
      _toast('加入失败：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
        if (!mounted) return;
        setState(() {
          _copyInto(_book, fresh);
        });
        _toast('已刷新');
      } else {
        _toast('刷新失败：${friendlyServerMessage(resp['errorMsg']?.toString())}');
      }
    } catch (e) {
      _toast('刷新失败：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用后端返回的新数据覆盖本地 Book 对象（Book 字段是可变的设计）
  void _copyInto(Book dst, Book src) {
    dst.name = src.name ?? dst.name;
    dst.author = src.author ?? dst.author;
    dst.coverUrl = src.coverUrl ?? dst.coverUrl;
    dst.customCoverUrl = src.customCoverUrl ?? dst.customCoverUrl;
    dst.intro = src.intro ?? dst.intro;
    dst.customIntro = src.customIntro ?? dst.customIntro;
    dst.kind = src.kind ?? dst.kind;
    dst.wordCount = src.wordCount ?? dst.wordCount;
    dst.latestChapterTitle = src.latestChapterTitle ?? dst.latestChapterTitle;
    dst.latestChapterTime = src.latestChapterTime ?? dst.latestChapterTime;
    dst.totalChapterNum = src.totalChapterNum ?? dst.totalChapterNum;
    dst.lastCheckTime = src.lastCheckTime ?? dst.lastCheckTime;
    dst.durChapterTitle = src.durChapterTitle ?? dst.durChapterTitle;
    dst.durChapterIndex = src.durChapterIndex ?? dst.durChapterIndex;
    dst.durChapterPos = src.durChapterPos ?? dst.durChapterPos;
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
    final token = _token;
    if (token.isEmpty) {
      _toast('请先登录');
      return;
    }
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => BookEditPage(book: _book, token: token),
      ),
    );
    if (saved == true && mounted) {
      setState(() {});
      context.read<BookshelfProvider>().applySort();
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

  /// 清除缓存：服务端缓存条目 + 本地章节缓存
  Future<void> _clearCache() async {
    final url = _book.bookUrl ?? '';
    if (url.isEmpty) {
      _toast('缺少书籍地址');
      return;
    }
    setState(() => _busy = true);
    var cleared = false;
    try {
      final cached =
          await LocalCacheService.instance.listChapterCacheBooks();
      final hash = LocalCacheService.instance.scopedKey(url);
      if (cached.any((b) => b.hash == hash || b.bookUrl == url)) {
        await LocalCacheService.instance.clearBookChapterCache(url);
        cleared = true;
      }
    } catch (_) {}
    try {
      // /fetchBook 会把这本书的目录缓存、正文缓存和缓存登记一起删掉，
      // 比只删 /getcancachelist 里那一条更彻底。
      await ApiService.instance.clearBookCache(_token, url);
      cleared = true;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(cleared ? '已清除缓存' : '这本书没有缓存');
  }

  /// 编辑「书籍变量」（书源里 `{{...}}` 用到的自定义变量）
  Future<void> _editVariable() async {
    final url = _book.bookUrl ?? '';
    if (url.isEmpty) {
      _toast('缺少书籍地址');
      return;
    }
    setState(() => _busy = true);
    String raw = '';
    try {
      raw = await ApiService.instance.getBookVariable(_token, url);
    } catch (e) {
      _toast('读取书籍变量失败：${friendlyError(e)}');
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    final ctl = TextEditingController(text: _prettyJson(raw));
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
    setState(() => _busy = true);
    try {
      await ApiService.instance.setBookVariable(_token, url, text);
      _book.variable = text.isEmpty ? null : text;
      _toast('已保存');
    } catch (e) {
      _toast('保存失败：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  Future<void> _showText(String title, String value) async {
    if (value.trim().isEmpty) {
      _toast('$title为空');
      return;
    }
    final copied = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(
          value,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('复制'),
          ),
        ],
      ),
    );
    if (copied == true) {
      await Clipboard.setData(ClipboardData(text: value));
      _toast('已复制');
    }
  }

  /// 加入服务端缓存队列（最多 5 本）
  Future<void> _cacheBook() async {
    final url = _book.bookUrl ?? '';
    if (url.isEmpty) {
      _toast('缺少书籍地址');
      return;
    }
    setState(() => _busy = true);
    try {
      final resp = await ApiService.instance.addCache(_token, url);
      if (resp['isSuccess'] == false) {
        // 服务端直接回中文原因（最多5个缓存任务 / 已在缓存进程中 / …）
        _toast(friendlyServerMessage(resp['errorMsg']?.toString()));
      } else {
        _toast('已加入缓存队列');
      }
    } catch (e) {
      _toast('缓存失败：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      _toast('修改失败：${friendlyError(e)}');
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
      _toast('修改失败：${friendlyError(e)}');
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
                    ? const Icon(Icons.check, color: BookDetailStyle.accent)
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
            style: FilledButton.styleFrom(
              backgroundColor: BookDetailStyle.danger,
            ),
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
      final url = _book.bookUrl ?? '';
      if (url.isNotEmpty) {
        await BookUpdatePrefs.setDisabled(url, false);
      }
      if (!mounted) return;
      final provider = context.read<BookshelfProvider>();
      provider.removeBookLocally(_book);
      _toast('已删除');
      if (_inShelf) Navigator.of(context).pop();
    } catch (e) {
      _toast('删除失败：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ 作者搜索

  /// 点作者名 → 打开搜索页，用作者名搜该作者名下所有书。
  ///
  /// 【为什么直接 push 而不是 pushNamed】
  /// `AppRoutes.routes` 里 `search` 那条 builder 是 `(_) => const SearchPage()`，
  /// 它会把 arguments 丢掉。这里只需要一个参数，直接 push 影响面最小。
  void _searchByAuthor() {
    final author = _book.author?.trim() ?? '';
    if (author.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(initialKeyword: author),
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

class _QuickAction {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
}
