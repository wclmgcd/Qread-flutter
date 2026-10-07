import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../config/routes.dart';
import '../../models/rss_source.dart';
import '../../providers/rss_manage_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/cookie_sync_service.dart';
import '../login/source_login_page.dart';
import '../login/webview_login_page.dart';
import 'rss_source_editor_page.dart';

class RssSourcePage extends StatefulWidget {
  const RssSourcePage({Key? key}) : super(key: key);

  @override
  State<RssSourcePage> createState() => _RssSourcePageState();
}

class _RssSourcePageState extends State<RssSourcePage> {
  bool _dataLoaded = false;
  bool _showSearch = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isLoggedIn = context.read<UserProvider>().isLoggedIn;
    if (isLoggedIn && !_dataLoaded) {
      _dataLoaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSources());
    } else if (!isLoggedIn) {
      _dataLoaded = false;
    }
  }

  Future<void> _loadSources() async {
    final token = context.read<UserProvider>().token;
    if (token == null) return;
    // 与书源页一致：不传 refresh，先上本地缓存再后台拉网络。
    await context.read<RssManageProvider>().loadSources(token);
    // 列表拉回来后顺手把**本地 WebView 里已有的** cookie 推到服务端。
    //
    // 【为什么订阅源页也要做这一步】
    // 订阅源（RSS）的取数是在**后端**跑的，读的是服务端的 CookieStore；
    // 而用户登录是在**客户端 WebView** 里完成的，cookie 落在 WebView 的
    // cookie jar。中间不搬一次，后端就是「明明登录过了，取订阅内容还是未登录」
    // —— 这正是「订阅源里的登录状态没有同步过来」。
    //
    // 书源页（source_manage_page.dart）一直有这一步，订阅源页漏了；
    // 只在「点登录 → 关页面」那一次调用 `syncOne` 是不够的：
    // 换设备、重装、或 cookie 是别处（网页端/官方 App）登录时，
    // 本地 WebView 里本来就有 cookie，但没有任何时机会推上去。
    unawaited(_pushLocalCookies(token));
  }

  /// 把本地 WebView 里已有的 cookie 批量推给服务端。
  ///
  /// `sourceUrl` 是订阅源标识、`loginUrl` 才是真正被登录的页面 ——
  /// 两者都可能有 cookie，一起交给 [CookieSyncService] 按站点去重
  /// （每个站点一次 HTTP，去重后通常远小于订阅源条数）。
  Future<void> _pushLocalCookies(String token) async {
    final provider = context.read<RssManageProvider>();
    final urls = <String>[];
    for (final s in provider.sources) {
      if ((s.sourceUrl ?? '').isNotEmpty) urls.add(s.sourceUrl!);
      if ((s.loginUrl ?? '').isNotEmpty) urls.add(s.loginUrl!);
    }
    await CookieSyncService.instance.pushMany(token, urls);
  }

  String _token() => context.read<UserProvider>().token ?? '';

  @override
  Widget build(BuildContext context) {
    final userProvider = context.watch<UserProvider>();
    final provider = context.watch<RssManageProvider>();

    return Scaffold(
      appBar: _buildAppBar(provider),
      body: _buildBody(userProvider, provider),
      // 【为什么没有 FloatingActionButton】
      // 与书源页（source_manage_page.dart）保持一致：官方 3.41 的列表页
      // 都不挂 FAB —— 一个圆形悬浮按钮压在列表右下角，既挡内容又抢焦点。
      // 「新建订阅源」改走右上角 ⋮ 菜单（见 _buildAppBar 的 'create'），
      // 列表为空时还有居中的「新建订阅源」按钮兜底（见 _buildEmpty）。
    );
  }

  PreferredSizeWidget _buildAppBar(RssManageProvider provider) {
    return AppBar(
      title: _showSearch
          ? TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索订阅源名称/URL/分组...',
                border: InputBorder.none,
              ),
              onChanged: provider.setSearchQuery,
            )
          : const Text('订阅源管理'),
      actions: [
        IconButton(
          icon: Icon(_showSearch ? Icons.close : Icons.search),
          tooltip: '搜索',
          onPressed: () {
            setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchController.clear();
                provider.setSearchQuery('');
              }
            });
          },
        ),
        if (!_showSearch)
          PopupMenuButton<String>(
            onSelected: (action) async {
              switch (action) {
                case 'create':
                  await _openCreateEditor();
                  break;
                case 'import':
                  _showImportDialog();
                  break;
                case 'export':
                  await _exportAll(provider);
                  break;
                case 'refresh':
                  _loadSources();
                  break;
              }
            },
            // 「新建订阅源」原先只有右下角那个 FAB 能进（空列表时才多一个
            // 居中按钮）。FAB 撤掉后必须在这里补回入口，否则列表非空时
            // 就没有任何新建途径了。只读账号不给这一项。
            itemBuilder: (context) => [
              if (provider.canEdit)
                const PopupMenuItem(value: 'create', child: Text('新建订阅源')),
              const PopupMenuItem(value: 'import', child: Text('导入订阅源')),
              const PopupMenuItem(value: 'export', child: Text('导出全部')),
              const PopupMenuItem(value: 'refresh', child: Text('刷新')),
            ],
          ),
      ],
    );
  }

  Widget _buildBody(UserProvider userProvider, RssManageProvider provider) {
    if (!userProvider.isLoggedIn) {
      return const Center(child: Text('请先登录'));
    }
    if (provider.loading && provider.sources.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.error != null && provider.sources.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(provider.error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadSources, child: const Text('重试')),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (provider.sources.isNotEmpty) _buildHeader(provider),
        Expanded(
          child: provider.sources.isEmpty
              ? _buildEmpty(provider.canEdit)
              : _buildList(provider),
        ),
      ],
    );
  }

  Widget _buildHeader(RssManageProvider provider) {
    return Column(
      children: [
        Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _MetricItem(label: '总数', value: provider.sources.length.toString()),
                const SizedBox(width: 24),
                _MetricItem(label: '启用', value: provider.enabledCount.toString()),
              ],
            ),
          ),
        ),
        if (!provider.canEdit)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '当前账号为只读模式，仅可查看订阅源',
              style: TextStyle(fontSize: 13, color: Colors.orange),
            ),
          ),
        if (provider.allGroups.isNotEmpty)
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: provider.allGroups.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final group = provider.allGroups[index];
                return FilterChip(
                  label: Text(group, style: const TextStyle(fontSize: 12)),
                  selected: provider.filterGroup == group,
                  onSelected: (_) => provider.setFilterGroup(group),
                  visualDensity: VisualDensity.compact,
                  selectedColor: const Color(0xFF009688).withValues(alpha: 0.2),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty(bool canEdit) {
    return RefreshIndicator(
      onRefresh: _loadSources,
      child: ListView(
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.rss_feed, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Center(child: Text('暂无订阅源')),
          if (canEdit) ...[
            const SizedBox(height: 16),
            Center(
              child: ElevatedButton.icon(
                onPressed: _openCreateEditor,
                icon: const Icon(Icons.add),
                label: const Text('新建订阅源'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildList(RssManageProvider provider) {
    // 【对齐书源页 / 3.41】列表平铺，顺序就是后端返回的顺序（「置顶/置底」
    // 调出来的次序不会被分组排序打乱）；分组名以方括号跟在订阅源名后面
    // （见 _RssSourceTile），不再单独占一行当分组标题。
    final list = provider.filteredSources;
    if (list.isEmpty) {
      return const Center(child: Text('无匹配结果'));
    }

    return RefreshIndicator(
      onRefresh: _loadSources,
      child: ListView.builder(
        // 底部 padding 从 80 收到 8：原来的 80 是给右下角 FAB 让位的，
        // FAB 撤掉后留着就是一块莫名其妙的空白。
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        itemCount: list.length,
        itemBuilder: (context, index) {
          final source = list[index];
          return _RssSourceTile(
            source: source,
            canEdit: provider.canEdit,
            onToggle: () => provider.toggleEnabled(_token(), source),
            onDelete: () => _confirmDelete(source),
            onTop: () => provider.topSource(_token(), source.sourceUrl ?? ''),
            onBottom: () =>
                provider.bottomSource(_token(), source.sourceUrl ?? ''),
            onEdit: () => _showEditDialog(provider, source),
            onExport: () => _exportOne(provider, source),
            onLogin: () => _showRssSourceLogin(source),
            onDebug: () => _showRssSourceDebug(source),
          );
        },
      ),
    );
  }

  void _showImportDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入订阅源'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '[{...}] 或 {...}',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx);
              final msg = await context.read<RssManageProvider>().importSources(_token(), text);
              if (msg != null && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
              }
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(RssSource source) {
    final id = source.sourceUrl ?? '';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除订阅源「${source.sourceName ?? id}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<RssManageProvider>().deleteSource(_token(), id);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditDialog(RssManageProvider provider, RssSource source) async {
    final raw = await provider.exportOne(_token(), source.sourceUrl ?? '');
    if (!mounted) return;
    final singleJson = _extractSingleSourceJson(raw ?? '');
    final changed = await Navigator.pushNamed(
      context,
      AppRoutes.rssSourceEditor,
      arguments: RssSourceEditorPageArgs(
        title: '编辑订阅源',
        id: source.sourceUrl,
        initialJson: singleJson,
      ),
    );
    if (changed == true && mounted) {
      _loadSources();
    }
  }

  Future<void> _exportAll(RssManageProvider provider) async {
    final json = await provider.exportAll(_token());
    if (json == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已导出全部订阅源 JSON 到剪贴板')),
    );
  }

  Future<void> _exportOne(RssManageProvider provider, RssSource source) async {
    final json = await provider.exportOne(_token(), source.sourceUrl ?? '');
    if (json == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出 ${source.sourceName ?? '订阅源'} JSON 到剪贴板')),
    );
  }

  Future<void> _showRssSourceLogin(RssSource source) async {
    final hasLoginUi = (source.loginUi ?? '').isNotEmpty;
    if (hasLoginUi) {
      await Navigator.pushNamed(
        context,
        AppRoutes.sourceLogin,
        arguments: SourceLoginPageArgs(
          sourceUrl: source.sourceUrl ?? '',
          sourceName: source.sourceName ?? '订阅源',
          type: 'rssSource',
          loginUi: source.loginUi,
          loginUrl: source.loginUrl,
          variableComment: source.variableComment,
          header: source.header,
        ),
      );
    } else if ((source.loginUrl ?? '').isNotEmpty) {
      await Navigator.pushNamed(
        context,
        AppRoutes.sourceWebLogin,
        arguments: WebViewLoginPageArgs(
          sourceUrl: source.sourceUrl ?? '',
          sourceName: source.sourceName ?? '订阅源',
          type: 'rssSource',
          loginUrl: source.loginUrl!,
          headers: _parseHeaderJson(source.header),
        ),
      );
    } else {
      return;
    }

    // 登录页回来后再同步这一个订阅源 —— 与书源页
    // （source_manage_page.dart 的 `_showSourceLogin`）保持完全一致。
    //
    // WebView 那条路在 `webview_login_page` 里「推完 cookie 再跑 login()」
    // 已经做过一次；但 JS 登录（loginUi）那条路的 cookie 是**服务端**自己拿的，
    // 客户端不知道，这里补一次双向同步，保证两边最终一致。
    //
    // 原来这个方法签名是 `void`，没有 await，返回后什么都不做 ——
    // 用户反馈的「订阅源里的登录状态没有同步过来」就有这一份原因。
    if (!mounted) return;
    final token = context.read<UserProvider>().token;
    if (token != null && token.isNotEmpty) {
      final url = (source.sourceUrl ?? '').isNotEmpty
          ? source.sourceUrl!
          : (source.loginUrl ?? '');
      unawaited(CookieSyncService.instance.syncOne(token, url));
    }
  }

  Map<String, String> _parseHeaderJson(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        return map.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  void _showRssSourceDebug(RssSource source) {
    Navigator.pushNamed(
      context,
      AppRoutes.rssSourceDebug,
      arguments: {
        'sourceUrl': source.sourceUrl ?? '',
        'sourceName': source.sourceName ?? '订阅源',
      },
    );
  }

  String _extractSingleSourceJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.isNotEmpty) {
        return jsonEncode(decoded.first);
      }
    } catch (_) {}
    return raw;
  }

  Future<void> _openCreateEditor() async {
    final changed = await Navigator.pushNamed(
      context,
      AppRoutes.rssSourceEditor,
      arguments: const RssSourceEditorPageArgs(
        title: '新建订阅源',
        initialJson: '{}',
      ),
    );
    if (changed == true && mounted) {
      _loadSources();
    }
  }
}

class _MetricItem extends StatelessWidget {
  final String label;
  final String value;

  const _MetricItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _RssSourceTile extends StatelessWidget {
  final RssSource source;
  final bool canEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTop;
  final VoidCallback onBottom;
  final VoidCallback onEdit;
  final VoidCallback onExport;
  final VoidCallback onLogin;
  final VoidCallback onDebug;

  const _RssSourceTile({
    required this.source,
    required this.canEdit,
    required this.onToggle,
    required this.onDelete,
    required this.onTop,
    required this.onBottom,
    required this.onEdit,
    required this.onExport,
    required this.onLogin,
    required this.onDebug,
  });

  @override
  Widget build(BuildContext context) {
    // 【对齐书源页 / 3.41】分组名以方括号跟在订阅源名后面（「知秋终版[QD]」），
    // 而不是单独占一行做分组标题 —— 列表因此可以平铺，顺序也就跟后端一致。
    final group = (source.sourceGroup ?? '').trim();
    final title = source.sourceName ?? '未命名订阅源';
    final label = group.isEmpty ? title : '$title[$group]';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    switch (action) {
                      case 'toggle':
                        onToggle();
                        break;
                      case 'login':
                        onLogin();
                        break;
                      case 'debug':
                        onDebug();
                        break;
                      case 'top':
                        onTop();
                        break;
                      case 'bottom':
                        onBottom();
                        break;
                      case 'edit':
                        onEdit();
                        break;
                      case 'export':
                        onExport();
                        break;
                      case 'delete':
                        onDelete();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    if (canEdit)
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(source.enabled == true ? '禁用' : '启用'),
                      ),
                    if ((source.loginUrl ?? '').isNotEmpty ||
                        (source.loginUi ?? '').isNotEmpty)
                      const PopupMenuItem(value: 'login', child: Text('登录')),
                    const PopupMenuItem(value: 'debug', child: Text('调试')),
                    if (canEdit) const PopupMenuItem(value: 'top', child: Text('置顶')),
                    if (canEdit) const PopupMenuItem(value: 'bottom', child: Text('置底')),
                    if (canEdit) const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    const PopupMenuItem(value: 'export', child: Text('导出')),
                    if (canEdit)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除', style: TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              source.sourceUrl ?? '',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if ((source.sourceComment ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                source.sourceComment!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StatusChip(
                  label: source.enabled == true ? '已启用' : '已禁用',
                  color: source.enabled == true ? const Color(0xFFE0F2F1) : const Color(0xFFF5F5F5),
                ),
                if ((source.loginUrl ?? '').isNotEmpty || (source.loginUi ?? '').isNotEmpty)
                  const _StatusChip(
                    label: '支持登录',
                    color: Color(0xFFE3F2FD),
                  ),
                if (source.enableJs == true)
                  const _StatusChip(
                    label: '启用 JS',
                    color: Color(0xFFFFF8E1),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}
