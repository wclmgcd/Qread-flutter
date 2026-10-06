import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../config/routes.dart';
import '../../models/book_source.dart';
import '../../providers/source_manage_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../login/source_login_page.dart';
import '../login/webview_login_page.dart';
import 'book_source_editor_page.dart';

class SourceManagePage extends StatefulWidget {
  const SourceManagePage({Key? key}) : super(key: key);

  @override
  State<SourceManagePage> createState() => _SourceManagePageState();
}

class _SourceManagePageState extends State<SourceManagePage> {
  bool _dataLoaded = false;

  /// A-Z 排序开关（3.41 书源管理 AppBar 上的 A-Z 按钮）
  bool _sortAZ = false;

  /// 导入 / 清理进行中，避免重复点击
  bool _importing = false;

  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showUnavailableDialog({
    required String title,
    required String message,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
    await context.read<SourceManageProvider>().loadSources(token, refresh: true);
  }

  String _token() => context.read<UserProvider>().token ?? '';

  @override
  Widget build(BuildContext context) {
    final userProvider = context.watch<UserProvider>();
    final provider = context.watch<SourceManageProvider>();

    return Scaffold(
      appBar: _buildAppBar(provider),
      body: _buildBody(userProvider, provider),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreateEditor,
        child: const Icon(Icons.add),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(SourceManageProvider provider) {
    // 常驻搜索框（对齐官方 3.41：标题位置就是搜索框，不用先点放大镜）
    //
    // 【对齐 3.41】勾选后 AppBar 不再切换成「已选 N 项」—— 3.41 的标题栏
    // 始终是搜索框，选中数量显示在底部批量栏的「全选 (n/m)」里。
    return AppBar(
      titleSpacing: 8,
      title: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索书源',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: provider.searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    provider.setSearchQuery('');
                    setState(() {});
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        onChanged: (v) {
          provider.setSearchQuery(v);
          setState(() {});
        },
      ),
      actions: [
        if (_importing)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.sort_by_alpha),
          tooltip: _sortAZ ? '取消 A-Z 排序' : 'A-Z 排序',
          color: _sortAZ ? const Color(0xFF009688) : null,
          onPressed: () => setState(() => _sortAZ = !_sortAZ),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.filter_list),
          tooltip: '筛选',
          onSelected: (v) {
            switch (v) {
              case 'all':
                provider.clearFilters();
                break;
              case 'enabled':
                provider.setFilterEnabledOnly(true);
                break;
              case 'disabled':
                provider.setFilterEnabledOnly(false);
                break;
              case 'explore':
                provider.toggleFilterExploreOnly();
                break;
            }
          },
          itemBuilder: (ctx) => [
            const PopupMenuItem(value: 'all', child: Text('全部分组')),
            const PopupMenuItem(value: 'enabled', child: Text('只看已启用')),
            const PopupMenuItem(value: 'disabled', child: Text('只看已禁用')),
            CheckedPopupMenuItem(
              value: 'explore',
              checked: provider.filterExploreOnly,
              child: const Text('只看已开发现'),
            ),
          ],
        ),
        // 【对齐 3.41】右上角 ⋮ 的菜单项与官方一一对应：
        // 刷新书源 / 新建书源 / 本地导入 / 网络导入 / 扫码导入 /
        // 清理cache / 清理cookie。
        // 原来多出来的「粘贴导入」「导出全部」已收掉：「粘贴导入」并进了
        // 「新建书源」入口，「导出」挪到批量栏的「更多」里（3.41 就在那儿）。
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          onSelected: (action) => _handleMenuAction(action),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'refresh', child: Text('刷新书源')),
            PopupMenuItem(value: 'create', child: Text('新建书源')),
            PopupMenuItem(value: 'import_local', child: Text('本地导入')),
            PopupMenuItem(value: 'import_net', child: Text('网络导入')),
            PopupMenuItem(value: 'import_qr', child: Text('扫码导入')),
            PopupMenuItem(value: 'clear_cache', child: Text('清理cache')),
            PopupMenuItem(value: 'clear_cookie', child: Text('清理cookie')),
          ],
        ),
      ],
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'import':
        _showImportDialog();
        break;
      case 'create':
        _openCreateEditor();
        break;
      case 'import_local':
        _importFromLocalFile();
        break;
      case 'import_net':
        _importFromNetwork();
        break;
      case 'import_qr':
        _importFromQr();
        break;
      case 'clear_cache':
        _confirmClear(cache: true);
        break;
      case 'clear_cookie':
        _confirmClear(cache: false);
        break;
      case 'export_all':
        _exportAll();
        break;
      case 'refresh':
        _dataLoaded = false;
        _loadSources();
        break;
    }
  }

  // ============================================================
  // 导入 / 清理（对齐 3.41 书源管理 ⋮ 菜单）
  // ============================================================

  /// 本地导入：选一个 JSON 文件导入书源
  Future<void> _importFromLocalFile() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json', 'txt']),
        ],
      );
      if (file == null) return;
      final content = await file.readAsString();
      await _importContent(content, label: file.name);
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 网络导入：输入 URL，把远端 JSON 当书源导入
  Future<void> _importFromNetwork() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('网络导入'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '书源 JSON 的下载地址（http/https）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final url = ctl.text.trim();
    ctl.dispose();
    if (ok != true || url.isEmpty) return;

    setState(() => _importing = true);
    try {
      final content = await ApiService.instance.fetchRemoteText(url);
      await _importContent(content, label: url);
    } catch (e) {
      _toast('网络导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 扫码导入：扫到的内容如果是 http 链接就走网络导入，否则当 JSON 处理
  Future<void> _importFromQr() async {
    _showUnavailableDialog(
      title: '扫码导入',
      message: '当前仓库还没有接入二维码扫描（需要额外的相机权限与扫码库）。\n'
          '可以先用「网络导入」把书源 JSON 的链接粘进来，效果是一样的。',
    );
  }

  /// 清理 cache / cookie
  Future<void> _confirmClear({required bool cache}) async {
    final token = _token();
    if (token.isEmpty) {
      _toast('请先登录');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(cache ? '清理 cache' : '清理 cookie'),
        content: Text(cache
            ? '会清空后端为所有书源缓存的章节/搜索数据，确定继续吗？'
            : '会清空所有书源的登录 cookie，需要重新登录的书源要再登一次，确定继续吗？'),
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
    setState(() => _importing = true);
    try {
      if (cache) {
        await ApiService.instance.cleanCaches(token);
      } else {
        await ApiService.instance.cleanCookies(token);
      }
      _toast(cache ? '已清理 cache' : '已清理 cookie');
    } catch (e) {
      _toast('清理失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 把一段书源 JSON 文本交给后端导入
  Future<void> _importContent(String content, {required String label}) async {
    final token = _token();
    if (token.isEmpty) {
      _toast('请先登录');
      return;
    }
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      _toast('内容为空');
      return;
    }
    try {
      jsonDecode(trimmed);
    } catch (_) {
      _toast('内容不是合法的 JSON');
      return;
    }
    setState(() => _importing = true);
    try {
      final resp = await ApiService.instance.saveBookSources(token, trimmed);
      if (resp['isSuccess'] == false) {
        _toast('导入失败：${resp['errorMsg'] ?? '未知错误'}');
        return;
      }
      _toast('导入成功（$label）');
      _dataLoaded = false;
      await _loadSources();
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildBody(UserProvider userProvider, SourceManageProvider provider) {
    if (!userProvider.isLoggedIn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.source_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('请先登录'),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/login'),
              child: const Text('去登录'),
            ),
          ],
        ),
      );
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
        // 【对齐 3.41】顶部不再放「统计卡片 + 分组 chips」：
        // 3.41 的书源页就是「搜索框 + 紧凑列表 + 常驻批量栏」，
        // 分组标题以普通文字插在列表里（见 _SourceGroupSection），
        // 按分组筛选走 AppBar 的漏斗按钮，不占列表顶部的位置。
        if (!provider.canEdit) _buildReadOnlyNotice(),
        Expanded(
          child: provider.sources.isEmpty
              ? _buildEmptyView()
              : _buildSourceList(provider),
        ),
        // 批量栏常驻（3.41 就是这样：0 选中时它也在，只是「删除/更多」置灰）
        if (provider.sources.isNotEmpty) _buildBatchBar(provider),
      ],
    );
  }

  Widget _buildReadOnlyNotice() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: Colors.orange),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前账号为只读模式，仅可查看书源',
              style: TextStyle(fontSize: 13, color: Colors.orange),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    return RefreshIndicator(
      onRefresh: _loadSources,
      child: ListView(
        children: [
          const SizedBox(height: 120),
          Column(
            children: [
              const Icon(Icons.source_outlined, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('暂无书源', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _openCreateEditor,
                icon: const Icon(Icons.add),
                label: const Text('新建书源'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSourceList(SourceManageProvider provider) {
    final grouped = provider.groupedSources;
    if (grouped.isEmpty) {
      return const Center(child: Text('无匹配结果'));
    }

    // A-Z 排序：组内按书源名排序（官方 3.41 AppBar 上的 A-Z 按钮）
    final entries = grouped.entries.map((e) {
      if (!_sortAZ) return MapEntry(e.key, e.value);
      final list = List<BookSource>.of(e.value)
        ..sort((a, b) =>
            (a.bookSourceName ?? '').compareTo(b.bookSourceName ?? ''));
      return MapEntry(e.key, list);
    }).toList();
    if (_sortAZ) {
      entries.sort((a, b) => a.key.compareTo(b.key));
    }

    return RefreshIndicator(
      onRefresh: _loadSources,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
        children: entries.map((entry) {
          return _SourceGroupSection(
            title: entry.key,
            sources: entry.value,
            provider: provider,
            canEdit: provider.canEdit,
            onToggleEnabled: (s) => provider.toggleEnabled(_token(), s),
            onToggleExplore: (s) => provider.toggleExploreEnabled(_token(), s),
            onDelete: (s) => _confirmDelete(s),
            onTop: (s) => provider.topSourceItem(_token(), s.bookSourceUrl ?? ''),
            onBottom: (s) => provider.bottomSourceItem(_token(), s.bookSourceUrl ?? ''),
            onEdit: (s) => _showEditDialog(s),
            onLogin: (s) => _showSourceLogin(s),
            onDebug: (s) => _showSourceDebug(s),
            isSelected: (id) => provider.selectedIds.contains(id),
            onToggleSelect: (id) => provider.toggleSelection(id),
            selectMode: provider.selectMode,
          );
        }).toList(),
      ),
    );
  }

  /// 批量操作栏（对齐 3.41）：全选(n/m) | 反选 | 删除 | 更多
  ///
  /// 【为什么改】原来是一整排**横向滚动**的按钮（启用/禁用/开启发现/关闭发现/
  /// 置顶/置底/分组/导出/删除），九个头等操作挤在一条横条里，用户得左右滑
  /// 才找得到，而且「删除」混在中间，容易误触。
  /// 3.41 只把「删除」留在栏上，其余全部收进「更多」弹出的底部菜单。
  Widget _buildBatchBar(SourceManageProvider provider) {
    final total = provider.sources.length;
    final selected = provider.selectedIds.length;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: SafeArea(
        child: Row(
          children: [
            TextButton(
              onPressed: () => provider.selectAll(),
              child: Text('全选 ($selected/$total)'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => provider.invertSelection(),
              child: const Text('反选'),
            ),
            // 一个都没勾的时候「删除 / 更多」置灰（对齐 3.41：
            // 0/34 时这两颗是灰的，勾上任意一条才亮）
            TextButton(
              onPressed: selected > 0 ? () => _confirmBatchDelete() : null,
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('删除'),
            ),
            TextButton(
              onPressed: selected > 0 ? () => _showBatchMoreSheet() : null,
              child: const Text('更多'),
            ),
          ],
        ),
      ),
    );
  }

  /// 「更多」底部菜单 —— 条目与顺序对齐 3.41。
  ///
  /// 【3.41 会根据「有没有勾选」换一套菜单】
  /// - 勾了书源：启用书源 / 禁用书源 / 启用发现 / 禁用发现 /
  ///   置顶所有 / 置底所有 / 添加分组 / 删除分组
  /// - 一个没勾：启用发现 / 禁用发现 / 置顶所有 / 置底所有 /
  ///   添加分组 / 删除分组 / 检验书源 / 导出书源
  /// 「检验书源」「导出书源」是**对全体**做的，所以只在没勾选时出现。
  Future<void> _showBatchMoreSheet() async {
    final provider = context.read<SourceManageProvider>();
    final token = _token();
    final hasSelection = provider.selectedIds.isNotEmpty;

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        void close() => Navigator.pop(sheetContext);
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasSelection) ...[
                  ListTile(
                    leading: const Icon(Icons.check_circle_outline),
                    title: const Text('启用书源'),
                    onTap: () {
                      close();
                      provider.batchSetEnabled(token, true);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.block),
                    title: const Text('禁用书源'),
                    onTap: () {
                      close();
                      provider.batchSetEnabled(token, false);
                    },
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.explore_outlined),
                  title: const Text('启用发现'),
                  onTap: () {
                    close();
                    provider.batchSetExploreEnabled(token, true);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.explore_off_outlined),
                  title: const Text('禁用发现'),
                  onTap: () {
                    close();
                    provider.batchSetExploreEnabled(token, false);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.vertical_align_top),
                  title: const Text('置顶所有'),
                  onTap: () {
                    close();
                    provider.batchTop(token);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.vertical_align_bottom),
                  title: const Text('置底所有'),
                  onTap: () {
                    close();
                    provider.batchBottom(token);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('添加分组'),
                  onTap: () {
                    close();
                    _showBatchGroupDialog(initialSt: '0');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.folder_delete_outlined),
                  title: const Text('删除分组'),
                  onTap: () {
                    close();
                    _showBatchGroupDialog(initialSt: '1');
                  },
                ),
                if (!hasSelection) ...[
                  ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: const Text('检验书源'),
                    onTap: () {
                      close();
                      _verifyAllSources();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.ios_share),
                    title: const Text('导出书源'),
                    onTap: () {
                      close();
                      _exportAll();
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 检验书源（对齐 3.41「更多」里的「检验书源」）。
  ///
  /// 【为什么是本地可达性检查】后端没有「逐源校验」的接口
  /// （`api_service.dart` 里没有 check / verify 之类的方法），所以这里自己
  /// 并发请求每个书源的主页 URL，把能连上 / 连不上的分别统计出来。
  /// 它验的是「书源站点还活着吗」，不等同于「搜索规则还能不能用」，
  /// 但比放一个点下去没反应的条目有用得多。
  Future<void> _verifyAllSources() async {
    final provider = context.read<SourceManageProvider>();
    final list = provider.filteredSources
        .where((s) => (s.bookSourceUrl ?? '').trim().isNotEmpty)
        .toList(growable: false);
    if (list.isEmpty) {
      _toast('没有可检验的书源');
      return;
    }
    _toast('正在检验 ${list.length} 个书源…');

    final ok = <String>[];
    final bad = <String>[];
    // 分批并发，避免一次打出去几十个请求被系统掐掉
    const concurrency = 6;
    for (var i = 0; i < list.length; i += concurrency) {
      final batch = list.skip(i).take(concurrency);
      await Future.wait(batch.map((s) async {
        final url = s.bookSourceUrl!;
        final name = (s.bookSourceName ?? url).trim();
        try {
          final resp = await Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 6),
            followRedirects: true,
            validateStatus: (c) => c != null && c < 500,
          )).get<dynamic>(url);
          final code = resp.statusCode ?? 0;
          if (code > 0 && code < 400) {
            ok.add(name);
          } else {
            bad.add('$name（HTTP $code）');
          }
        } catch (_) {
          bad.add('$name（连接失败）');
        }
      }));
    }

    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检验书源'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('可用 ${ok.length} 个，不可用 ${bad.length} 个'),
              if (bad.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('不可用：',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final n in bad)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text('· $n', style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ============ Dialogs ============

  void _confirmDelete(BookSource source) {
    final id = source.bookSourceUrl ?? '';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除书源「${source.bookSourceName ?? id}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<SourceManageProvider>().deleteSource(_token(), id);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _confirmBatchDelete() {
    final provider = context.read<SourceManageProvider>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认批量删除'),
        content: Text('确定要删除选中的 ${provider.selectedIds.length} 个书源吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              provider.batchDelete(_token());
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showImportDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入书源'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('粘贴书源 JSON 内容（支持单个或数组）',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 10,
                decoration: const InputDecoration(
                  hintText: '[{...}] 或 {...}',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx);
              final provider = context.read<SourceManageProvider>();
              final msg = await provider.importSources(_token(), text);
              if (msg != null && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(msg)),
                );
              }
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BookSource source) async {
    final detail = await context.read<SourceManageProvider>().getSourceDetail(
      _token(),
      source.bookSourceUrl ?? '',
    );
    final jsonStr = detail?['data']?['json']?.toString() ?? '';

    if (!mounted) return;
    final changed = await Navigator.pushNamed(
      context,
      AppRoutes.bookSourceEditor,
      arguments: BookSourceEditorPageArgs(
        title: '编辑书源',
        id: source.bookSourceUrl,
        initialJson: jsonStr,
      ),
    );
    if (changed == true && mounted) {
      _loadSources();
    }
  }

  void _showSourceLogin(BookSource source) {
    final hasLoginUi =
        (source.loginUi ?? '').isNotEmpty;
    if (hasLoginUi) {
      Navigator.pushNamed(
        context,
        AppRoutes.sourceLogin,
        arguments: SourceLoginPageArgs(
          sourceUrl: source.bookSourceUrl ?? '',
          sourceName: source.bookSourceName ?? '书源',
          type: 'bookSource',
          loginUi: source.loginUi,
          loginUrl: source.loginUrl,
          variableComment: source.variableComment,
          header: source.header,
        ),
      );
    } else if ((source.loginUrl ?? '').isNotEmpty) {
      Navigator.pushNamed(
        context,
        AppRoutes.sourceWebLogin,
        arguments: WebViewLoginPageArgs(
          sourceUrl: source.bookSourceUrl ?? '',
          sourceName: source.bookSourceName ?? '书源',
          type: 'bookSource',
          loginUrl: source.loginUrl!,
          headers: _parseHeaderJson(source.header),
        ),
      );
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

  void _showSourceDebug(BookSource source) {
    Navigator.pushNamed(
      context,
      AppRoutes.sourceDebug,
      arguments: {
        'sourceUrl': source.bookSourceUrl ?? '',
        'sourceName': source.bookSourceName ?? '书源',
        'checkKeyWord': source.checkKeyWord ?? '系统',
        'exploreUrl': source.exploreUrl ?? '',
      },
    );
  }

  /// 批量改分组。
  ///
  /// [initialSt] 决定默认落在哪一段：'0' = 添加分组，'1' = 移除分组。
  /// 「更多」菜单里「添加分组 / 删除分组」是两个独立入口，分别传 '0' / '1'，
  /// 这样用户点进来就是想要的那一段，不用再手动切换。
  void _showBatchGroupDialog({String initialSt = '0'}) {
    final groupController = TextEditingController();
    String st = initialSt; // 0=添加分组, 1=移除分组
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('修改分组'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: '0', label: Text('添加分组')),
                  ButtonSegment(value: '1', label: Text('移除分组')),
                ],
                selected: {st},
                onSelectionChanged: (v) => setDialogState(() => st = v.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: groupController,
                decoration: InputDecoration(
                  hintText: st == '0' ? '输入分组名称' : '输入要移除的分组名',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.read<SourceManageProvider>().batchEditGroup(
                  _token(),
                  st: st,
                  group: groupController.text.trim(),
                );
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportAll() async {
    final provider = context.read<SourceManageProvider>();
    final messenger = ScaffoldMessenger.of(context);
    provider.selectAll();
    final json = await provider.exportSelectedSources(_token());
    provider.clearSelection();
    if (json != null && mounted) {
      await Clipboard.setData(ClipboardData(text: json));
      messenger.showSnackBar(
        const SnackBar(content: Text('已导出全部书源 JSON 到剪贴板')),
      );
    }
  }

  Future<void> _openCreateEditor() async {
    final changed = await Navigator.pushNamed(
      context,
      AppRoutes.bookSourceEditor,
      arguments: const BookSourceEditorPageArgs(
        title: '新建书源',
        initialJson: '{}',
      ),
    );
    if (changed == true && mounted) {
      _loadSources();
    }
  }
}

// ============ Components ============

class _SourceGroupSection extends StatelessWidget {
  final String title;
  final List<BookSource> sources;
  final SourceManageProvider provider;
  final bool canEdit;
  final void Function(BookSource) onToggleEnabled;
  final void Function(BookSource) onToggleExplore;
  final void Function(BookSource) onDelete;
  final void Function(BookSource) onTop;
  final void Function(BookSource) onBottom;
  final void Function(BookSource) onEdit;
  final void Function(BookSource) onLogin;
  final void Function(BookSource) onDebug;
  final bool Function(String) isSelected;
  final void Function(String) onToggleSelect;
  final bool selectMode;

  const _SourceGroupSection({
    required this.title,
    required this.sources,
    required this.provider,
    required this.canEdit,
    required this.onToggleEnabled,
    required this.onToggleExplore,
    required this.onDelete,
    required this.onTop,
    required this.onBottom,
    required this.onEdit,
    required this.onLogin,
    required this.onDebug,
    required this.isSelected,
    required this.onToggleSelect,
    required this.selectMode,
  });

  @override
  Widget build(BuildContext context) {
    // 【对齐 3.41】分组不再包成 Card，标题就是一行普通文字。
    // 原来每个分组一张卡、卡里每条书源再一个带边框的小卡，
    // 一层套一层，一屏只能看到两三条书源。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
          child: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        ...sources.map((source) => _SourceTile(
              source: source,
              canEdit: canEdit,
              onToggleEnabled: () => onToggleEnabled(source),
              onToggleExplore: () => onToggleExplore(source),
              onDelete: () => onDelete(source),
              onTop: () => onTop(source),
              onBottom: () => onBottom(source),
              onEdit: () => onEdit(source),
              onLogin: () => onLogin(source),
              onDebug: () => onDebug(source),
              selected: isSelected(source.bookSourceUrl ?? ''),
              onToggleSelect: () => onToggleSelect(source.bookSourceUrl ?? ''),
              selectMode: selectMode,
            )),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  final BookSource source;
  final bool canEdit;
  final VoidCallback onToggleEnabled;
  final VoidCallback onToggleExplore;
  final VoidCallback onDelete;
  final VoidCallback onTop;
  final VoidCallback onBottom;
  final VoidCallback onEdit;
  final VoidCallback onLogin;
  final VoidCallback onDebug;
  final bool selected;
  final VoidCallback onToggleSelect;
  final bool selectMode;

  const _SourceTile({
    required this.source,
    required this.canEdit,
    required this.onToggleEnabled,
    required this.onToggleExplore,
    required this.onDelete,
    required this.onTop,
    required this.onBottom,
    required this.onEdit,
    required this.onLogin,
    required this.onDebug,
    required this.selected,
    required this.onToggleSelect,
    required this.selectMode,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = source.enabled == true;
    // 【对齐 3.41】一行一条：复选框 + 名称 + 开关 + 编辑笔 + ⋮。
    //
    // 原来每条书源是一个带边框的小卡片，里面塞了 url、备注、三个状态 chip，
    // 一屏只能看两三条。3.41 是紧凑行 —— url / 备注 / 状态都收进 ⋮ 里，
    // 列表本身只留「一眼扫过去就能找到书名」的信息。
    return InkWell(
      onTap: selectMode ? onToggleSelect : (canEdit ? onEdit : null),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Row(
          children: [
            // 复选框常驻（对齐 3.41：不用先点「批量管理」，直接勾）
            InkWell(
              onTap: onToggleSelect,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  color: selected ? const Color(0xFF009688) : Colors.grey,
                  size: 22,
                ),
              ),
            ),
            Expanded(
              child: Text(
                source.bookSourceName ?? '未命名书源',
                style: const TextStyle(fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (canEdit) ...[
              // 行内开关（对齐官方 3.41：每行右侧直接一个启用开关，
              // 不用先点 ⋮ 再选「启用/禁用」）
              Transform.scale(
                scale: 0.72,
                child: Switch(
                  value: enabled,
                  onChanged: (_) => onToggleEnabled(),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: '编辑',
                visualDensity: VisualDensity.compact,
                onPressed: onEdit,
              ),
            ],
            PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              iconSize: 20,
              constraints: const BoxConstraints(),
              onSelected: (action) {
                switch (action) {
                  case 'toggle':
                    onToggleEnabled();
                    break;
                  case 'toggleExplore':
                    onToggleExplore();
                    break;
                  case 'login':
                    onLogin();
                    break;
                  case 'debug':
                    onDebug();
                    break;
                  case 'edit':
                    onEdit();
                    break;
                  case 'top':
                    onTop();
                    break;
                  case 'bottom':
                    onBottom();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(enabled ? '禁用' : '启用'),
                ),
                PopupMenuItem(
                  value: 'toggleExplore',
                  child: Text(source.enabledExplore == true ? '关闭发现' : '开启发现'),
                ),
                if ((source.loginUrl ?? '').isNotEmpty ||
                    (source.loginUi ?? '').isNotEmpty)
                  const PopupMenuItem(value: 'login', child: Text('登录')),
                const PopupMenuItem(value: 'debug', child: Text('调试')),
                const PopupMenuItem(value: 'edit', child: Text('编辑')),
                const PopupMenuItem(value: 'top', child: Text('置顶')),
                const PopupMenuItem(value: 'bottom', child: Text('置底')),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
