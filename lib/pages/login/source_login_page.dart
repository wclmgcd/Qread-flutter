import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/row_ui.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/cookie_sync_service.dart';
import '../../services/reader_ws_service.dart';
import '../reader/paragraph_comment_page.dart';
import 'webview_login_page.dart';

class SourceLoginPageArgs {
  final String sourceUrl;
  final String sourceName;
  final String type; // "bookSource" or "rssSource"
  final String? loginUi;
  final String? loginUrl;
  final String? variableComment;
  final String? header;

  const SourceLoginPageArgs({
    required this.sourceUrl,
    required this.sourceName,
    required this.type,
    this.loginUi,
    this.loginUrl,
    this.variableComment,
    this.header,
  });

  Map<String, String> get headerMap {
    if (header == null || header!.isEmpty) return {};
    try {
      final map = jsonDecode(header!);
      if (map is Map) {
        return map.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }
}

class SourceLoginPage extends StatefulWidget {
  final SourceLoginPageArgs args;

  const SourceLoginPage({Key? key, required this.args}) : super(key: key);

  @override
  State<SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<SourceLoginPage> {
  final _formKey = GlobalKey<FormState>();
  List<RowUi> _rows = [];
  Map<String, String> _loginData = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// 正在执行的动作名（按钮上显示「检测中…」，避免用户连点）
  String? _runningAction;

  /// 本次动作执行期间，后端通过 WebSocket 推回来的内容。
  ///
  /// 【为什么结果要从 WebSocket 拿】
  /// 上游 `/action` 只回 `JsonResponse(true)`，**不携带任何结果**。书源 JS
  /// 想给用户看的东西，走的是 `ws?id=<token>` 这条长连接：
  ///   - `java.upLoginData({...})` → `upLoginData` 消息，`title` 是 JSON
  ///   - `java.copyText("...")`    → `copyText` 消息，`title` 就是要复制的文本
  ///   - `App.noticy`              → `noticy` 消息（后端目前没有调用方，留着对齐协议）
  /// 官方客户端也是从这条通道收的。
  ///
  /// 【局限】书源 JS 里只写 `return "✅查询成功…"`、不走上面推送的，
  /// 这条链路拿不到 —— 这是上游 `/action` 接口本身的形状决定的。
  /// 兜底是动作结束后读一次 `/getLoginInfo`（JS 存进 userInfo 的内容）。
  final List<String> _wsResults = [];
  bool _actionRunning = false;

  /// 进页面时 `/getLoginInfo` 读到的原始内容，用来判断动作有没有改动登录态
  /// （没变就不必弹一遍旧信息）
  String _initialLoginInfo = '';

  StreamSubscription<WsPushMessage>? _wsSub;
  StreamSubscription<WsPushMessage>? _toastSub;

  bool get _isBookSource => widget.args.type == 'bookSource';

  @override
  void initState() {
    super.initState();
    // 书源 JS 的结果是走 WebSocket 推回来的（见 _wsResults 的说明），
    // 所以登录页也要把长连接拉起来。ReaderWsService 是全局单例，
    // 这里只订阅、不负责断开 —— 连接的生命周期归它自己管。
    _wsSub = ReaderWsService.instance.pushStream.listen(_onWsPush);
    _toastSub = ReaderWsService.instance.toastStream.listen(_onWsToast);
    unawaited(ReaderWsService.instance.connect(
      context.read<UserProvider>().token,
    ));
    _loadLoginUi();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _toastSub?.cancel();
    super.dispose();
  }

  // ============================================================
  // WebSocket 推送
  // ============================================================

  void _onWsPush(WsPushMessage msg) {
    // 书源 JS 里的 `java.startBrowser` / `startBrowserAwait` / `showBrowser`
    // 会让后端推一条「打开网页」的消息过来 ——「书源设置中心」「更新书源」
    // 「番茄登录」这类按钮都走它。登录页不接的话，`startBrowserAwait` 会一直
    // 干等到 120s 超时，用户看到的就是「点了没反应」。
    if (msg.isOpenPage) {
      _openBackendPage(msg);
      return;
    }
    switch (msg.msg) {
      case 'upLoginData':
        _collectWsResult(_prettyJson(msg.title), '登录信息已更新');
        break;
      case 'copyText':
        final text = msg.title;
        if (text.trim().isEmpty) break;
        Clipboard.setData(ClipboardData(text: text));
        _collectWsResult(text, '已复制到剪贴板');
        if (!_actionRunning && mounted) _toast('已复制到剪贴板');
        break;
      case 'noticy':
        _collectWsResult(msg.title, '后端提示');
        break;
    }
  }

  /// `toast` / `longToast` 提示。
  ///
  /// 书源按钮的结果几乎全靠 `java.longToast("✅查询成功\n用户：…")` 报出来 ——
  /// 这是**多行文本**，SnackBar 装不下（也会一闪而过），所以按 3.41 的观感
  /// 走弹框；单行的 `toast` 仍然用 SnackBar。
  void _onWsToast(WsPushMessage msg) {
    final text = msg.str.trim();
    if (text.isEmpty) return;
    if (msg.msg == 'longToast') {
      _collectWsResult(text, '后端提示');
    } else if (!_actionRunning && mounted) {
      _toast(text);
    }
  }

  /// 打开后端让开的网页，并用 [ParagraphCommentPage] 负责关闭时回执
  /// `/savehtml`，释放后端的 `startBrowserAwait` 等待。
  ///
  /// 用整屏（`embedded: false`）而不是阅读页那种半截式弹窗：设置中心 / 更新页
  /// 都是要整屏填的表单，半截式放不下。
  ///
  /// 【关页面后为什么要同步 cookie】
  /// `register()` / `fq_login()` / `loginqt()` 这些动作都是
  /// `java.startBrowserAwait(url, title)`（第三参 `refetchAfterSuccess=true`）——
  /// 后端会**阻塞等用户把网页关掉**，然后用**后端自己的** cookie 仓重新抓一次这个
  /// URL。用户在 WebView 里登录产生的 cookie 只存在客户端，不推上去后端就看不见，
  /// 于是「登录了但没登录」。所以页面 pop 之后必须把该站点的 cookie 推给后端。
  void _openBackendPage(WsPushMessage msg) {
    final url = msg.url.trim();
    if (url.isEmpty || !mounted) return;
    final token = context.read<UserProvider>().token;
    unawaited(
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => ParagraphCommentPage(
                url: url,
                title: msg.title.trim().isEmpty
                    ? widget.args.sourceName
                    : msg.title.trim(),
                headers: msg.headerMap,
                requestId: msg.id,
                token: token,
              ),
            ),
          )
          .then((_) async {
            // `data:` 开头的地址（书源把整页 HTML base64 塞进 URL）没有域名，
            // registrableDomain 会返回空，syncOne 内部直接跳过。
            await CookieSyncService.instance.syncOne(token, url);
            if (!mounted) return;
            // 登录类动作的结果通常在关页面之后才由后端推回来，这里重新拉一次
            // 登录信息兜底，避免用户看到「已执行」但什么都没变。
            await _refreshLoginInfoAfterAction();
          }),
    );
  }

  /// 动作执行完 / 关掉后端网页后，拉一次 `/getLoginInfo` 看看内容有没有变
  Future<void> _refreshLoginInfoAfterAction() async {
    final token = context.read<UserProvider>().token;
    try {
      final resp = _isBookSource
          ? await ApiService.instance.getSourcesLoginInfo(
              token, widget.args.sourceUrl)
          : await ApiService.instance.getRssLoginInfo(
              token, widget.args.sourceUrl);
      final data = resp['data']?.toString() ?? '';
      if (!mounted) return;
      if (data.isEmpty || data == '{}' || data == _initialLoginInfo) return;
      _initialLoginInfo = data;
      final text = _prettyJson(data);
      if (text.trim().isEmpty) return;
      // 动作期间已经报过结果就别重复弹
      if (_wsResults.isNotEmpty) return;
      _showActionResult('登录信息已更新', text);
    } catch (_) {}
  }

  void _collectWsResult(String text, String title) {
    if (text.trim().isEmpty) return;
    _wsResults.add(text);
    // 动作进行中先攒着，等遮罩撤掉再统一弹，免得和遮罩抢焦点
    if (_actionRunning || !mounted) return;
    _showActionResult(title, text);
  }

  /// 推送内容多半是 JSON，缩进一下更好读；不是 JSON 就原样返回
  String _prettyJson(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _loadLoginUi() async {
    setState(() => _loading = true);
    try {
      final api = ApiService.instance;
      final token = context.read<UserProvider>().token ?? '';

      // 先试书源列表里带回来的那份 loginUi。
      //
      // 【为什么判据是「解析出几行」而不是「非空」】
      // `@js:` 形式的 loginUi（整个 UI 由 JS 拼出来，知秋终版 / 大灰狼都用它）
      // 在书源列表接口里拿不到求值结果：后端只把原始串原样返回，
      // `GSON.fromJsonArray` 失败时甚至变成字符串 "null"。这两种都「非空」，
      // 但 `parseLoginUi` 解析出来是空列表 —— 页面就一个按钮都没有。
      var rows = parseLoginUi(widget.args.loginUi);
      if (rows.isEmpty) {
        // `/getSourcesloginui` 会在服务端把 `@js:` 跑成 JSON 数组
        Map<String, dynamic> resp;
        if (_isBookSource) {
          resp = await api.getSourcesloginui(token, url: widget.args.sourceUrl);
        } else {
          resp = await api.getRssSourcesloginui(token, widget.args.sourceUrl);
        }
        final data = resp['data'];
        if (data is String && data.isNotEmpty) {
          rows = parseLoginUi(data);
        } else if (data is List) {
          rows = data
              .map((e) => RowUi.fromJson(e is Map<String, dynamic> ? e : {}))
              .toList();
        }
      }
      _rows = rows;

      _loginData = defaultLoginData(_rows);

      // Load existing login info
      // 同时记下原始内容：动作执行完读 `/getLoginInfo` 兜底时，要拿它比对，
      // 没变化就不弹（否则点「检测登录」会把进页面时就有的旧信息再弹一遍）
      if (_isBookSource) {
        final resp = await api.getSourcesLoginInfo(token, widget.args.sourceUrl);
        final data = resp['data'];
        if (data is String && data.isNotEmpty && data != '{}') {
          _initialLoginInfo = data;
          _fillFromSaved(data);
        }
      } else {
        final resp = await api.getRssLoginInfo(token, widget.args.sourceUrl);
        final data = resp['data'];
        if (data is String && data.isNotEmpty && data != '{}') {
          _initialLoginInfo = data;
          _fillFromSaved(data);
        }
      }
    } catch (e) {
      // 兜底：至少把本地那份 loginUi 显示出来。
      // 注意只在 `_rows` 还是空的时候才覆盖 —— 后面读 `/getLoginInfo` 失败也会
      // 走到这里，不能把前面已经从后端求值好的行列表冲掉。
      if (_rows.isEmpty) {
        _rows = parseLoginUi(widget.args.loginUi);
        _loginData = defaultLoginData(_rows);
      }
    }
    setState(() => _loading = false);
  }

  void _fillFromSaved(String json) {
    try {
      final map = Uri.tryParse('?$json')?.queryParameters;
      if (map != null) {
        setState(() {
          for (final entry in map.entries) {
            if (_loginData.containsKey(entry.key)) {
              _loginData[entry.key] = entry.value;
            }
          }
        });
        return;
      }
    } catch (_) {}
    try {
      final map = Map<String, dynamic>.from(
        jsonDecode(json) as Map,
      );
      setState(() {
        for (final entry in map.entries) {
          if (_loginData.containsKey(entry.key)) {
            _loginData[entry.key] = entry.value?.toString() ?? '';
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _handleButtonAction(RowUi row) async {
    if (row.action == null) return;
    final action = row.action!;

    // Sync current form values before reading _loginData
    _formKey.currentState?.save();

    // Check if it's an absolute URL
    if (action.startsWith('http://') || action.startsWith('https://')) {
      final uri = Uri.tryParse(action);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }

    // Non-URL action: treat as JS, send to backend
    setState(() => _runningAction = row.name);
    _wsResults.clear();
    _actionRunning = true;
    try {
      final api = ApiService.instance;
      final token = context.read<UserProvider>().token ?? '';
      if (_isBookSource) {
        await api.sourcesAction(
          token,
          bookSourceUrl: widget.args.sourceUrl,
          action: action,
          info: _encodeLoginData(),
        );
      } else {
        // RSS: save login info first, then execute action
        await api.putRssLoginInfo(
            token, widget.args.sourceUrl, _encodeLoginData());
        await api.rssaction(token, widget.args.sourceUrl, action);
      }

      // 【结果不在 HTTP 响应里】上游 `/action` 只回 `JsonResponse(true)`，
      // 书源 JS 的结果是走 WebSocket 推回来的（见 _wsResults 的说明）。
      // 推送和响应是两条独立的路，推送往往稍晚一点到，这里等一下再收网。
      await Future<void>.delayed(const Duration(milliseconds: 900));

      // 兜底：JS 若把结果写进了 userInfo（`source.putLoginInfo(...)`），
      // 从 `/getLoginInfo` 能读回来。与进页面时读到的内容比对，没变就不算
      // 结果 —— 否则点「检测登录」会把进页面时就有的旧信息再弹一遍。
      var fallback = '';
      try {
        final resp = _isBookSource
            ? await api.getSourcesLoginInfo(token, widget.args.sourceUrl)
            : await api.getRssLoginInfo(token, widget.args.sourceUrl);
        final data = resp['data']?.toString() ?? '';
        if (data.isNotEmpty && data != '{}' && data != _initialLoginInfo) {
          fallback = _prettyJson(data);
        }
      } catch (_) {
        // 兜底失败不影响已经收到的推送
      }

      if (!mounted) return;
      _actionRunning = false;

      // 推送优先：书源 JS 已经用 longToast 报过结果了，就别再拿 /getLoginInfo
      // 的兜底内容重复一遍
      final text = _wsResults.isNotEmpty ? _wsResults.join('\n\n') : fallback;

      if (text.trim().isEmpty) {
        _toast('动作 "${row.name}" 已执行');
      } else {
        _showActionResult(row.name, text);
      }
    } catch (e) {
      if (mounted) _toast('动作执行失败: $e');
    } finally {
      _actionRunning = false;
      if (mounted) setState(() => _runningAction = null);
    }
  }

  /// 弹出动作的执行结果。
  ///
  /// 内容来自后端 WebSocket 推送（`upLoginData` / `copyText`）或
  /// `/getLoginInfo` 兜底 —— 上游 `/action` 自己不返回结果，见 [_wsResults]。
  void _showActionResult(String title, String text) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('✅ $title'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.5,
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveLoginData() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _saving = true);
    try {
      final api = ApiService.instance;
      final token = context.read<UserProvider>().token ?? '';
      final info = _encodeLoginData();

      if (_isBookSource) {
        await api.putSourcesLoginInfo(token, widget.args.sourceUrl, info);
      } else {
        await api.putRssLoginInfo(token, widget.args.sourceUrl, info);
        // Also execute login if loginUrl exists
        if (widget.args.loginUrl != null && widget.args.loginUrl!.isNotEmpty) {
          await api.rssaction(token, widget.args.sourceUrl, 'login');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录信息已保存')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _encodeLoginData() {
    final filtered = <String, String>{};
    _loginData.forEach((key, value) {
      if (value.isNotEmpty) filtered[key] = value;
    });
    return jsonEncode(filtered);
  }

  Future<void> _navigateToWebLogin() async {
    final result = await Navigator.of(context).pushNamed(
      '/source/weblogin',
      arguments: WebViewLoginPageArgs(
        sourceUrl: widget.args.sourceUrl,
        sourceName: widget.args.sourceName,
        type: widget.args.type,
        loginUrl: widget.args.loginUrl ?? widget.args.sourceUrl,
        headers: widget.args.headerMap,
      ),
    );
    if (result == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _showVariableDialog() async {
    final api = ApiService.instance;
    final token = context.read<UserProvider>().token ?? '';

    String currentValue = '';
    try {
      if (_isBookSource) {
        final resp = await api.getSourcesVariable(token, widget.args.sourceUrl);
        currentValue = resp['data']?.toString() ?? '';
      } else {
        final resp = await api.getRssVariable(token, widget.args.sourceUrl);
        currentValue = resp['data']?.toString() ?? '';
      }
    } catch (_) {}

    if (!mounted) return;

    final controller = TextEditingController(text: currentValue);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('源变量'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.args.variableComment != null &&
                widget.args.variableComment!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  widget.args.variableComment!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '输入变量值',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null && mounted) {
      try {
        if (_isBookSource) {
          await api.setSourcesVariable(token, widget.args.sourceUrl, result);
        } else {
          await api.setRssVariable(token, widget.args.sourceUrl, result);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('变量已保存')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('变量保存失败: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('登录 - ${widget.args.sourceName}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            tooltip: '源变量',
            onPressed: _showVariableDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadLoginUi,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _rows.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('该源没有登录表单'),
                          const SizedBox(height: 16),
                          if (widget.args.loginUrl != null &&
                              widget.args.loginUrl!.isNotEmpty)
                            ElevatedButton.icon(
                              icon: const Icon(Icons.language),
                              label: const Text('使用网页登录'),
                              onPressed: _navigateToWebLogin,
                            ),
                        ],
                      ),
                    )
                  : Form(
                      key: _formKey,
                      child: Stack(
                        children: [
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              // 【对齐 3.41】输入框在上面，按钮收成一整块网格排在下面
                              // （原来是按 loginUi 顺序逐条平铺，按钮被拉成整行宽）
                              ..._rows
                                  .where((r) => !r.isButton)
                                  .map(_buildRow),
                              if (_rows.any((r) => r.isButton)) ...[
                                const SizedBox(height: 8),
                                _buildButtonWrap(),
                              ],
                              const SizedBox(height: 24),
                              _buildActionButtons(),
                            ],
                          ),
                          // 动作执行中：压一层遮罩，防止连点
                          if (_runningAction != null)
                            Positioned.fill(
                              child: ColoredBox(
                                color: Colors.black.withValues(alpha: 0.25),
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 14),
                                    decoration: BoxDecoration(
                                      color: const Color(0xD91A222B),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          '$_runningAction中…',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
    );
  }

  /// 登录界面上的动作按钮 —— 3.41 是一整块自动换行的「胶囊网格」
  Widget _buildButtonWrap() {
    final buttons = _rows.where((r) => r.isButton).toList(growable: false);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final row in buttons)
          OutlinedButton(
            onPressed:
                _runningAction == null ? () => _handleButtonAction(row) : null,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Text(row.name, style: const TextStyle(fontSize: 13)),
          ),
      ],
    );
  }

  Widget _buildRow(RowUi row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        initialValue: _loginData[row.name] ?? '',
        obscureText: row.isPassword,
        decoration: InputDecoration(
          labelText: row.name,
          border: const OutlineInputBorder(),
        ),
        onSaved: (value) => _loginData[row.name] = value ?? '',
        validator: (value) => null,
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          icon: _saving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: const Text('保存登录信息'),
          onPressed: _saving ? null : _saveLoginData,
        ),
        const SizedBox(height: 12),
        if (widget.args.loginUrl != null &&
            widget.args.loginUrl!.isNotEmpty)
          OutlinedButton.icon(
            icon: const Icon(Icons.language),
            label: const Text('使用网页登录'),
            onPressed: _navigateToWebLogin,
          ),
      ],
    );
  }
}
