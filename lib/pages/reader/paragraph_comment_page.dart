import 'dart:async';

import 'package:flutter/material.dart';

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

  /// 最后一次加载完成时的整页 HTML（AdaptiveWebView.onPageHtml 缓存）。
  /// 回执时随 cookie 一起给后端 —— 官方的 115KB 回执包里就有它。
  String _lastHtml = '';

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
        await ApiService.instance.noCookies(token, id: id);
        return;
      }
      await ApiService.instance
          .saveCookies(token, widget.url, cookies, html: _lastHtml, id: id);
    } catch (_) {
      // 回执失败无所谓：后端 120s 会自己超时
    }
  }

  @override
  Widget build(BuildContext context) {
    final webView = AdaptiveWebView(
      url: widget.url,
      enableJs: true,
      headers: widget.headers,
      onPageHtml: (html) => _lastHtml = html,
    );

    // 半截式弹窗：容器由调用方给，这里不要 Scaffold / AppBar
    if (widget.embedded) return webView;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? '段评' : widget.title),
      ),
      body: webView,
    );
  }
}
