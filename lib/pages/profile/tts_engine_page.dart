import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/tts_engine.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/storage_service.dart';

/// 朗读引擎管理页
///
/// 对齐官方 3.41「我的 → 朗读引擎」：管理 legado 格式的 HTTP TTS 引擎，
/// 支持新增 / 编辑 / 删除 / 导入 JSON（直接粘贴 tts.json 的内容）。
/// 引擎存在后端（`/getalltts`），本页只做展示与增删改。
class TtsEnginePage extends StatefulWidget {
  const TtsEnginePage({Key? key}) : super(key: key);

  @override
  State<TtsEnginePage> createState() => _TtsEnginePageState();
}

class _TtsEnginePageState extends State<TtsEnginePage> {
  /// 当前选中的引擎 id（本地保存，阅读器朗读时用它去请求 /tts）
  static const _kSelectedTts = 'tts_selected_engine_id';

  List<TtsEngine> _engines = [];
  bool _loading = true;
  String? _error;
  String? _selectedId;

  String get _token => context.read<UserProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_token.isEmpty) {
      setState(() {
        _loading = false;
        _error = '请先登录';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final storage = await StorageService.instance;
      final list = await ApiService.instance.getAllTts(_token);
      if (!mounted) return;
      setState(() {
        _engines = list;
        _selectedId = storage.readString(_kSelectedTts);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _select(TtsEngine engine) async {
    final id = engine.id;
    if (id == null || id.isEmpty) return;
    final storage = await StorageService.instance;
    await storage.setString(_kSelectedTts, id);
    if (!mounted) return;
    setState(() => _selectedId = id);
    _toast('已选择「${engine.name}」');
  }

  Future<void> _edit([TtsEngine? engine]) async {
    final result = await showDialog<TtsEngine>(
      context: context,
      builder: (_) => _TtsEditorDialog(engine: engine),
    );
    if (result == null) return;
    try {
      final resp = await ApiService.instance.addTts(_token, result);
      if (resp['isSuccess'] == true) {
        _toast(engine == null ? '已添加' : '已保存');
        await _load();
      } else {
        _toast('保存失败：${resp['errorMsg'] ?? '未知错误'}');
      }
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _delete(TtsEngine engine) async {
    final id = engine.id;
    if (id == null || id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除朗读引擎'),
        content: Text('确定删除「${engine.name}」吗？'),
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
    try {
      final resp = await ApiService.instance.delTts(_token, id);
      if (resp['isSuccess'] == true) {
        if (_selectedId == id) {
          final storage = await StorageService.instance;
          await storage.remove(_kSelectedTts);
          _selectedId = null;
        }
        _toast('已删除');
        await _load();
      } else {
        _toast('删除失败：${resp['errorMsg'] ?? '未知错误'}');
      }
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  /// 导入 JSON（粘贴或选文件），内容是 legado 的引擎数组
  Future<void> _import({required bool fromFile}) async {
    String? content;
    if (fromFile) {
      const typeGroup = XTypeGroup(label: 'JSON', extensions: ['json']);
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null) return;
      content = await file.readAsString();
    } else {
      content = await _promptForJson();
    }
    if (content == null || content.trim().isEmpty) return;

    try {
      final resp = await ApiService.instance.saveTtsList(_token, content);
      if (resp['isSuccess'] == true) {
        _toast(resp['errorMsg']?.toString() ?? '导入完成');
        await _load();
      } else {
        _toast('导入失败：${resp['errorMsg'] ?? '未知错误'}');
      }
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<String?> _promptForJson() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入朗读引擎'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '粘贴 JSON（如 tts.json 的内容）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('朗读引擎'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'paste':
                  _import(fromFile: false);
                  break;
                case 'file':
                  _import(fromFile: true);
                  break;
                case 'refresh':
                  _load();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'paste', child: Text('粘贴导入')),
              PopupMenuItem(value: 'file', child: Text('本地导入')),
              PopupMenuItem(value: 'refresh', child: Text('刷新')),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(),
        tooltip: '新增引擎',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_engines.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.record_voice_over_outlined,
                size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('还没有朗读引擎'),
            SizedBox(height: 6),
            Text('可以点右下角新增，或用右上角菜单导入 JSON',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _engines.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
      itemBuilder: (_, i) => _buildTile(_engines[i]),
    );
  }

  Widget _buildTile(TtsEngine engine) {
    final selected = _selectedId != null && _selectedId == engine.id;
    return ListTile(
      leading: Icon(
        selected ? Icons.check_circle : Icons.record_voice_over_outlined,
        color: selected ? const Color(0xFF00A88F) : Colors.grey.shade600,
      ),
      title: Text(
        engine.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        engine.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (v) {
          if (v == 'edit') {
            _edit(engine);
          } else if (v == 'delete') {
            _delete(engine);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('编辑')),
          PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
      onTap: () => _select(engine),
    );
  }
}

/// 新增 / 编辑引擎的对话框
class _TtsEditorDialog extends StatefulWidget {
  const _TtsEditorDialog({this.engine});

  final TtsEngine? engine;

  @override
  State<_TtsEditorDialog> createState() => _TtsEditorDialogState();
}

class _TtsEditorDialogState extends State<_TtsEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _header;
  late final TextEditingController _contentType;

  @override
  void initState() {
    super.initState();
    final e = widget.engine;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.url ?? '');
    _header = TextEditingController(text: e?.header ?? '');
    _contentType = TextEditingController(text: e?.contentType ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _header.dispose();
    _contentType.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.engine == null ? '新增朗读引擎' : '编辑朗读引擎'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '接口地址（url）',
                hintText:
                    'https://.../synthesis?voiceName=xxx&rate={{speakSpeed/10}}&text={{speakText}}',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentType,
              decoration: const InputDecoration(
                labelText: 'contentType（留空默认 audio/mpeg）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _header,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '请求头 header（可留空）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final url = _url.text.trim();
            if (name.isEmpty || url.isEmpty) return;
            final original = widget.engine;
            Navigator.pop(
              context,
              original == null
                  ? TtsEngine(
                      name: name,
                      url: url,
                      header: _header.text.trim(),
                      contentType: _contentType.text.trim(),
                    )
                  // 用 copyWith 保留 loginUrl / loginUi / loginCheckJs /
                  // enabledCookieJar / concurrentRate 等未在表单里暴露的字段
                  : original.copyWith(
                      name: name,
                      url: url,
                      header: _header.text.trim(),
                      contentType: _contentType.text.trim(),
                    ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
