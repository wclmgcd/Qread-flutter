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
      await controller.loadRequest(
        Uri.parse(widget.url),
        headers: widget.headers,
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
