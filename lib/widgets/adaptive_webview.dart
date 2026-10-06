import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

typedef CustomSchemeHandler = Future<void> Function(String url);

/// 跨端 WebView 封装。
///
/// 上游原本还接了 Windows 的 `webview_windows`，但那个包唯一版本 0.4.0 的
/// `environment.sdk` 是 `>=2.13.0 <3.0.0`（Dart 2 专属），会把整个依赖图
/// 锁死在 Dart 2，导致 `flutter pub get` 直接失败。本 fork 只出 Android，
/// 因此移除了 Windows 分支；对外 API 保持不变，调用方无需改动。
///
/// 如果以后要恢复 Windows 支持，正确做法是「条件导入 + 独立的 win 实现文件」，
/// 而不是像上游那样无条件 `import`——否则 Android 也会把 Windows 的 Dart 代码
/// 一起编进 AOT 产物。
class AdaptiveWebView extends StatefulWidget {
  final String url;
  final bool enableJs;
  final String? injectJs;
  final Map<String, String> headers;
  final CustomSchemeHandler? onCustomScheme;

  const AdaptiveWebView({
    Key? key,
    required this.url,
    required this.enableJs,
    this.injectJs,
    this.headers = const {},
    this.onCustomScheme,
  }) : super(key: key);

  @override
  State<AdaptiveWebView> createState() => _AdaptiveWebViewState();
}

class _AdaptiveWebViewState extends State<AdaptiveWebView> {
  WebViewController? _mobileController;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initMobile();
  }

  Future<void> _initMobile() async {
    try {
      late final WebViewController controller;
      controller = WebViewController()
        ..setJavaScriptMode(
          widget.enableJs
              ? JavaScriptMode.unrestricted
              : JavaScriptMode.disabled,
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) async {
              final url = request.url;
              if (_isCustomScheme(url)) {
                await widget.onCustomScheme?.call(url);
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onPageStarted: (_) {
              if (mounted) setState(() => _loading = true);
            },
            onPageFinished: (_) async {
              final js = widget.injectJs;
              if (js != null && js.isNotEmpty) {
                try {
                  await controller.runJavaScript(js);
                } catch (_) {}
              }
              if (mounted) setState(() => _loading = false);
            },
          ),
        );

      _mobileController = controller;
      await _load(controller, widget.url, widget.headers);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 加载一个地址。
  ///
  /// 【为什么要特判 `data:text/html`】
  /// 书源的「书源设置中心 / 更新书源 / 使用教程」这类按钮不跳外链，而是**在 JS 里
  /// 拼一整页 HTML**，再 `java.startBrowser('data:text/html;base64,...')` 交给客户端
  /// （见后端 `JsExtensions.startBrowser` → `App.startBrowserAwait`）。这种地址：
  ///   - 长度可以到几十 KB（整页 HTML base64 后更大）
  ///   - 不是网络地址，`WebView.loadUrl` 在部分 ROM 上会直接拒绝，页面全白
  ///
  /// 所以先按普通地址走；**失败**再自己解出 HTML 用 `loadHtmlString` 兜底。
  /// 顺序不能反：正常 http(s) 页面必须走 `loadRequest`（要带 header、要能跳转）。
  Future<void> _load(
    WebViewController controller,
    String url,
    Map<String, String> headers,
  ) async {
    try {
      await controller.loadRequest(Uri.parse(url), headers: headers);
    } catch (_) {
      final html = _decodeDataUrl(url);
      if (html == null) rethrow;
      await controller.loadHtmlString(html);
    }
  }

  /// `data:text/html;base64,<...>` / `data:text/html,<urlencoded>` → HTML 文本
  static String? _decodeDataUrl(String url) {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    final meta = url.substring(5, comma);
    final payload = url.substring(comma + 1);
    if (!meta.toLowerCase().contains('html')) return null;
    try {
      if (meta.toLowerCase().contains('base64')) {
        return utf8.decode(base64.decode(payload));
      }
      return Uri.decodeComponent(payload);
    } catch (_) {
      return null;
    }
  }

  bool _isCustomScheme(String url) {
    return url.startsWith('yuedu://') || url.startsWith('legado://');
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _buildError();
    }

    final body = _mobileController == null
        ? const SizedBox.shrink()
        : WebViewWidget(controller: _mobileController!);

    return Stack(
      children: [
        Positioned.fill(child: body),
        if (_loading) const Center(child: CircularProgressIndicator()),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 40),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ),
      ),
    );
  }
}
