import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/rss_manage_provider.dart';
import '../../providers/source_manage_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/cookie_sync_service.dart';
import '../../widgets/adaptive_webview.dart';

/// 段评页
///
/// 段评内容由后端渲染，客户端只负责把后端推来的 URL + header 用 WebView 打开。
/// 这条链路是：
///   正文里的段评气泡（内联 `<img>`，带 `click: showCmt(...)`）
///     → 客户端 POST `/getopenurl?url=<js>showCmt(...)</js>`
///     → 后端在书源 JS 里执行 showCmt，构造出段评页 URL
///     → 后端通过 WebSocket 推 `startBrowser` / `startBrowserdp`
///     → 客户端打开本页
///
/// 后端那侧是 `startBrowserAwait`，会等一个回执（最多 120s），且放行后
/// 立刻用**服务端**的 cookie 仓重抓该 URL（`refetchAfterSuccess=true`）。
/// 所以回执走 `/saveCookies`，把 cookie+html+id 一次带齐（服务端先落盘
/// cookie 再放行，时序有保证）；本地没 cookie 时走 `/noCookies`。
class ParagraphCommentPage extends StatefulWidget {
  const ParagraphCommentPage({
    Key? key,
    required this.url,
    this.title = '段评',
    this.headers = const {},
    this.requestId,
    this.token,
    this.embedded = false,
  }) : super(key: key);

  final String url;
  final String title;
  final Map<String, String> headers;

  /// 后端推送消息里的 id，用于回执
  final String? requestId;
  final String? token;

  /// true = 只渲染 WebView 本身，不套 Scaffold / AppBar。
  ///
  /// 用于「半截式底部弹出」：圆角容器、标题栏、关闭按钮、背景遮罩都由调用方
  /// （reader_page._openWebPage → showHalfSheet）提供，这里只负责内容和关闭回执。
  final bool embedded;

  @override
  State<ParagraphCommentPage> createState() => _ParagraphCommentPageState();
}

class _ParagraphCommentPageState extends State<ParagraphCommentPage> {
  bool _responded = false;
  WebViewController? _controller;
  bool _closing = false;

  /// 最后一次加载完成时的整页 HTML（AdaptiveWebView.onPageHtml 缓存）。
  /// 回执时随 cookie 一起给后端 —— 官方的 115KB 回执包里就有它。
  String _lastHtml = '';

  /// 「书源设置中心」右上角 ✓：替用户点页面自己的保存控件（[kSyncSettingsJs]，
  /// 与远端设置页右上角那个勾等价），等结果节点写好后再取 DOM 交给后端。
  Future<void> _saveSettings() async {
    if (_closing) return;
    setState(() => _closing = true);
    final controller = _controller;
    if (controller == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    var clicked = false;
    try {
      // 脚本返回 Promise，webview_flutter 4.x 会等它落定再回值。
      final raw = await controller.runJavaScriptReturningResult(kSyncSettingsJs);
      clicked = raw == true || raw == 'true';
    } catch (_) {}
    // 结果节点没写内容时同步不会报错，只能等超时回 false；先把 DOM 取回来，
    // 结果节点里只要有配置就按成功处理（部分书源只更新节点、不重写 cookie）。
    await _captureHtml();
    final hasResult = _lastHtml.contains('source-settings-result') ||
        _lastHtml.contains('source-settings-final-result');
    if (!clicked && !hasResult) {
      setState(() => _closing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未读取到设置结果，已保留原配置')),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _captureHtml() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final raw = await controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      _lastHtml = _decodeJsString(raw);
    } catch (_) {}
  }

  static String _decodeJsString(Object? raw) {
    if (raw == null) return '';
    final s = raw.toString();
    try {
      final decoded = jsonDecode(s);
      return decoded is String ? decoded : s;
    } catch (_) {
      return s;
    }
  }

  @override
  void dispose() {
    _respondToBackend();
    super.dispose();
  }

  /// 回执给后端，释放 startBrowserAwait 的等待。
  ///
  /// 一次 `saveCookies` 调用把「该站 cookie + html + id」带齐：服务端先落盘
  /// cookie、再 `completeRequest` 放行，书源 JS 放行后立刻
  /// `cookie.getCookie(url)` / 重抓页面都能拿到刚登录的态。拆成「`/savehtml`
  /// 先放行 + 事后补推 cookie」顺序是反的 —— 大灰狼「🍅番茄登录」(`fq_login`)
  /// 就是这么一直登录不上的。
  ///
  /// 本地读不到 cookie 时改走 `/noCookies`：`/saveCookies` 传空串会把服务端
  /// 该站点的存货清掉（见 ApiService.saveCookies 的说明）。
  ///
  /// dispose 里 fire-and-forget 是安全的：存 cookie 和放行在**同一个**服务端
  /// 请求里完成，不存在时序竞争。
  void _respondToBackend() {
    if (_responded) return;
    _responded = true;
    final id = widget.requestId;
    final token = widget.token;
    if (id == null || id.isEmpty || token == null || token.isEmpty) return;
    unawaited(_deliverReceipt(token, id));
  }

  Future<void> _deliverReceipt(String token, String id) async {
    try {
      final cookies =
          await CookieSyncService.instance.readLocalJoined(widget.url);
      if (cookies.isEmpty) {
        // 书源设置中心是 data: 页，本来就没有 cookie，但书源 JS 要从回执的
        // html 里读结果；回空 cookie 前先把页面交上去，否则设置永远不保存。
        if (_lastHtml.trim().isNotEmpty) {
          await ApiService.instance.saveHtml(token, id: id, html: _lastHtml);
        } else {
          await ApiService.instance.noCookies(token, id: id);
        }
        return;
      }
      await ApiService.instance
          .saveCookies(token, widget.url, cookies, html: _lastHtml, id: id);
    } catch (_) {
      // 回执失败无所谓：后端 120s 会自己超时
    }
  }

  /// 更新页（`renderVersionPage`）里的「更新书源」是
  /// `yuedu://booksource/importonline?src=<下载地址>`。这个协议会被 WebView
  /// 拦下来；不在这里处理就等于点了没反应。
  Future<void> _handleImportScheme(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return;
    String? type;
    String? src;
    if (uri.scheme == 'yuedu') {
      type = uri.host.toLowerCase();
      src = uri.queryParameters['src'];
    } else if (uri.scheme == 'legado' &&
        uri.host.toLowerCase() == 'import' &&
        uri.pathSegments.isNotEmpty) {
      type = uri.pathSegments.first.toLowerCase();
      src = uri.queryParameters['src'];
    }
    final messenger = ScaffoldMessenger.of(context);
    if (type == null || src == null || src.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('无法识别导入链接')));
      return;
    }
    final downloadUri = Uri.tryParse(src);
    if (downloadUri == null ||
        !const ['http', 'https'].contains(downloadUri.scheme) ||
        downloadUri.host.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('导入地址无效')));
      return;
    }
    final token = context.read<UserProvider>().token;
    if (token == null || token.isEmpty) return;
    if (type != 'booksource' && type != 'rsssource') {
      messenger.showSnackBar(SnackBar(content: Text('暂不支持导入类型: $type')));
      return;
    }
    // 更新书源会新增/覆盖服务端书源，先让用户确认，避免误触整批导入。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('更新书源'),
        content: const Text('将从书源服务器下载并导入最新书源，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final sourceProvider = context.read<SourceManageProvider>();
    try {
      final content = await ApiService.instance.fetchRemoteText(src);
      if (content.trim().isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('导入内容为空')));
        return;
      }
      final result = type == 'booksource'
          ? await sourceProvider.importSources(token, content)
          : await _importRss(token, content);
      messenger.showSnackBar(SnackBar(content: Text(result ?? '导入失败')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败: $e')));
    }
  }

  Future<String?> _importRss(String token, String content) async {
    if (!mounted) return null;
    try {
      final rss = context.read<RssManageProvider>();
      return await rss.importSources(token, content);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSettings = widget.url.startsWith('data:text/html');
    final webView = AdaptiveWebView(
      url: widget.url,
      enableJs: true,
      headers: widget.headers,
      onController: (controller) => _controller = controller,
      onCustomScheme: _handleImportScheme,
      onPageHtml: (html) => _lastHtml = html,
    );

    // 半截式弹窗：容器由调用方给，这里不要 Scaffold / AppBar
    if (widget.embedded) return webView;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? '段评' : widget.title),
        actions: [
          if (isSettings)
            IconButton(
              tooltip: '保存并关闭',
              icon: const Icon(Icons.check),
              onPressed: _closing ? null : () => unawaited(_saveSettings()),
            ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: webView),
          if (_closing)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x88000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

/// 点一下书源设置页自己的保存控件（右上角的 ✓ / 「保存」），让页面**自己**把
/// 当前控件状态写进 [`source-settings-result`] / [`source-settings-final-result`]
/// 和 `source_settings_result` cookie（远端页 `syncResult()` 的写法）。
///
/// 远端页的状态锁在闭包里，外部拿不到 `state`；页面自己不动手的话，结果节点
/// 还是打开时的初始配置 —— 这正是「选了但保存不上」的原因。
///
/// 查找顺序：先按文字（✓ / 保存配置 / 保存设置 / 保存），再按图标 class
/// （`check` / `save` 一类）；都没有时退回 `window.syncResult()`。点了控件就
/// 不再补调 `syncResult`，否则会把页面刚写好的结果再覆盖回去。
///
/// 返回 Promise<bool>：保存逻辑可能是异步的，等两个结果节点里出现内容（或超时）
/// 再让调用方去取 DOM。
const kSyncSettingsJs = r'''
(function () {
  function pick() {
    var labels = ['✓', '✔', '保存配置', '保存设置', '保存'];
    var nodes = document.querySelectorAll(
      'button, a, [role="button"], .btn, [class*="save"], [class*="check"], [class*="confirm"]');
    for (var i = 0; i < nodes.length; i++) {
      var text = (nodes[i].textContent || '').replace(/\s/g, '');
      for (var j = 0; j < labels.length; j++) {
        if (text === labels[j]) return nodes[i];
      }
    }
    for (var k = 0; k < nodes.length; k++) {
      var cls = ' ' + (nodes[k].className || '') + ' ';
      if (/[ _-](save|check)/i.test(cls)) return nodes[k];
    }
    return null;
  }
  function settled() {
    var ids = ['source-settings-result', 'source-settings-final-result'];
    for (var i = 0; i < ids.length; i++) {
      var el = document.getElementById(ids[i]);
      if (el && el.textContent) return true;
    }
    return false;
  }
  try {
    var target = pick();
    if (target) {
      target.click();
    } else if (typeof window.syncResult === 'function') {
      window.syncResult();
    } else {
      return false;
    }
    return new Promise(function (resolve) {
      if (settled()) return resolve(true);
      var tries = 0;
      var timer = setInterval(function () {
        if (settled()) {
          clearInterval(timer);
          return resolve(true);
        }
        if (++tries > 30) {
          clearInterval(timer);
          resolve(false);
        }
      }, 100);
    });
  } catch (e) {
    return false;
  }
})();
'''
