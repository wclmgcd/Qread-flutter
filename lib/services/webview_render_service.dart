import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_service.dart';
import 'reader_ws_service.dart';

/// 后端 `webview` / `webviewbody` 推送的处理：用一个**不挂到界面上的**
/// （headless）WebView 真实加载页面，把渲染后的整页 HTML 回给后端。
///
/// 【这条链路是什么】
/// 书源 JS 里的 `java.webview(html, url, js)` / `java.webviewbody(...)`
/// （read 后端 `InitConfig.kt` 的 `App.webview/webviewbody`）：有些页面是
/// JS 渲染出来的，服务端直接 HTTP 抓拿到的是空壳。后端把页面参数推给客户端，
/// 客户端用真 WebView 跑一遍，把 `document.documentElement.outerHTML` 回传。
///
/// 【协议形状】
/// - 推送：WebMessage，`msg` 恒为 "webview"（webviewbody 也是它，区别只在
///   `body` 非空 → 用 POST 加载），`url`/`html` 二选一，`title` 是要注入
///   执行的 JS，`header` JSON 串，`urlregex` 命中才算"到达目标页"（表单
///   提交后跳转到目标 URL 才抓），`overrideUrlRegex` 命中的导航直接拦截，
///   `id` 回执 id。
/// - 回执：`POST /savehtml`，`id` + `html` = 整页 HTML 文本（失败回空串）。
///
/// 【为什么是 headless 而不是弹页面】
/// 这是数据抓取，不是给人看的 —— 官方客户端也是无界面完成。webview_flutter
/// 4.x 的 WebViewController 不 attach WebViewWidget 也能 load / 跑 JS。
class WebviewRenderService {
  WebviewRenderService._();
  static final WebviewRenderService instance = WebviewRenderService._();

  /// 与后端 `AppConst.defaultuserAgent` 对齐的兜底 UA。
  static const String fallbackUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Version/4.0 Chrome/128.0.0.0 Mobile DuckDuckGo/5 Safari/537.36';

  String? _cachedUa;

  /// 处理一条 webview 推送并回执。永不抛 —— 失败回空串放行后端。
  Future<void> handle(WsPushMessage msg, String token) async {
    String html = '';
    try {
      html = await renderToHtml(
        url: msg.url,
        html: msg.html,
        js: msg.title,
        headers: msg.headerMap,
        body: msg.body,
        urlRegex: msg.urlRegex,
        overrideUrlRegex: msg.overrideUrlRegex,
      );
    } catch (e) {
      debugPrint('webview 渲染失败(${msg.url}): $e');
    }
    if (msg.id.isEmpty || token.isEmpty) return;
    try {
      await ApiService.instance.saveHtml(token, id: msg.id, html: html);
    } catch (e) {
      debugPrint('webview 回执失败: $e');
    }
  }

  /// 客户端 WebView 的真实 UA（getWebViewUA 回执用）。
  ///
  /// 结果缓存 —— 同一进程里 UA 不会变。读不到（Web 端 / 异常）用
  /// [fallbackUserAgent]，与后端拿不到回执时的兜底值一致。
  Future<String> webViewUserAgent() async {
    final cached = _cachedUa;
    if (cached != null && cached.isNotEmpty) return cached;
    if (!kIsWeb) {
      try {
        final controller = WebViewController();
        final result = await controller
            .runJavaScriptReturningResult('navigator.userAgent')
            .timeout(const Duration(seconds: 8));
        final ua = decodeJsString(result);
        if (ua.isNotEmpty) {
          _cachedUa = ua;
          return ua;
        }
      } catch (_) {}
    }
    return fallbackUserAgent;
  }

  /// headless 渲染并返回整页 HTML；任何失败/超时都返回空串。
  ///
  /// [timeout] 必须小于后端的 120s WaitForResponse，留足回执时间。
  Future<String> renderToHtml({
    required String url,
    required String html,
    required String js,
    required Map<String, String> headers,
    String body = '',
    String urlRegex = '',
    String overrideUrlRegex = '',
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // Web 端没有可用的 headless WebView（webview_flutter 无 Web 实现）。
    if (kIsWeb) return '';
    if (url.trim().isEmpty && html.isEmpty) return '';

    WebViewController controller;
    try {
      controller = WebViewController();
    } catch (e) {
      // 不支持 WebView 的平台（如桌面端）
      debugPrint('WebView 不可用: $e');
      return '';
    }

    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);

      // UA 走 setUserAgent：Android/iOS 都不允许用 loadRequest 的 headers
      // 覆盖 User-Agent。
      final ua = _userAgentOf(headers);
      if (ua != null && ua.isNotEmpty) {
        await controller.setUserAgent(ua);
      }

      final done = Completer<String>();
      Timer? timer;
      var finished = false;

      void finish(String value) {
        if (finished) return;
        finished = true;
        timer?.cancel();
        if (!done.isCompleted) done.complete(value);
      }

      RegExp? urlPattern;
      RegExp? overridePattern;
      try {
        if (urlRegex.isNotEmpty) urlPattern = RegExp(urlRegex);
        if (overrideUrlRegex.isNotEmpty) {
          overridePattern = RegExp(overrideUrlRegex);
        }
      } catch (_) {
        // 书源给坏正则：urlRegex 失效等同于"无条件完成"，override 失效等同于不拦截
      }

      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (overridePattern != null &&
              overridePattern.hasMatch(request.url)) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageFinished: (finishedUrl) async {
          if (finished) return;
          // urlRegex 是"到达目标页"的判据：表单提交后的中间跳转不算，
          // 继续等下一跳。给了坏正则/没给 → 第一个 onPageFinished 就抓。
          if (urlPattern != null && !urlPattern.hasMatch(finishedUrl)) return;
          var out = '';
          try {
            if (js.isNotEmpty) {
              await controller.runJavaScript(js);
              // JS 可能触发异步渲染（DOM 改写），稍等再抓
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
            final result = await controller.runJavaScriptReturningResult(
                'document.documentElement.outerHTML');
            out = decodeJsString(result);
          } catch (_) {}
          finish(out);
        },
      ));

      final loadHeaders = Map<String, String>.from(headers)
        ..removeWhere((k, _) => k.toLowerCase() == 'user-agent');

      if (url.trim().isNotEmpty) {
        final uri = Uri.parse(url);
        if (body.isNotEmpty) {
          await controller.loadRequest(
            uri,
            method: LoadRequestMethod.post,
            headers: loadHeaders,
            body: Uint8List.fromList(utf8.encode(body)),
          );
        } else {
          await controller.loadRequest(uri, headers: loadHeaders);
        }
      } else {
        await controller.loadHtmlString(html);
      }

      timer = Timer(timeout, () => finish(''));
      return done.future;
    } catch (e) {
      debugPrint('webview 渲染异常: $e');
      return '';
    }
  }

  static String? _userAgentOf(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'user-agent') return entry.value;
    }
    return null;
  }

  /// `runJavaScriptReturningResult` 的返回值：字符串结果是 JSON 编码的
  /// （带引号、转义），其它类型原样 toString。解不出来就当原文用。
  static String decodeJsString(Object? result) {
    if (result == null) return '';
    final raw = result.toString();
    if (raw.isEmpty || raw == 'null') return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
      return decoded.toString();
    } catch (_) {
      return raw;
    }
  }
}
