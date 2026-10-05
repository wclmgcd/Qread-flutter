import 'package:flutter/material.dart';

import '../../services/api_service.dart';
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
/// 后端那侧是 `startBrowserAwait`，会等一个回执（最多 120s），
/// 所以页面关闭时补一个 `/savehtml` 回执，避免后端线程干等。
class ParagraphCommentPage extends StatefulWidget {
  const ParagraphCommentPage({
    Key? key,
    required this.url,
    this.title = '段评',
    this.headers = const {},
    this.requestId,
    this.token,
  }) : super(key: key);

  final String url;
  final String title;
  final Map<String, String> headers;

  /// 后端推送消息里的 id，用于回执
  final String? requestId;
  final String? token;

  @override
  State<ParagraphCommentPage> createState() => _ParagraphCommentPageState();
}

class _ParagraphCommentPageState extends State<ParagraphCommentPage> {
  bool _responded = false;

  @override
  void dispose() {
    _respondToBackend();
    super.dispose();
  }

  /// 回执给后端，释放 startBrowserAwait 的等待
  void _respondToBackend() {
    if (_responded) return;
    _responded = true;
    final id = widget.requestId;
    final token = widget.token;
    if (id == null || id.isEmpty || token == null || token.isEmpty) return;
    // 不需要结果，失败也无所谓（后端 120s 会自己超时）
    ApiService.instance.saveHtml(token, id: id, html: '').ignore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? '段评' : widget.title),
      ),
      body: AdaptiveWebView(
        url: widget.url,
        enableJs: true,
        headers: widget.headers,
      ),
    );
  }
}
