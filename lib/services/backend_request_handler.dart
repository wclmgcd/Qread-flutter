import 'package:flutter/material.dart';

import '../config/routes.dart';
import 'api_service.dart';
import 'backend_proxy_service.dart';
import 'reader_ws_service.dart';
import 'webview_render_service.dart';

/// 后端「请求-响应」型 WS 推送的统一入口。
///
/// 后端 `WaitForResponse(id, 120s)` 阻塞等回执的消息都在这里接住：
///
/// | msg                            | 处理                                    | 回执内容          |
/// |--------------------------------|-----------------------------------------|-------------------|
/// | head / get / post              | [BackendProxyService] 客户端代理发请求  | MyResponse JSON   |
/// | webview（含 webviewbody）      | [WebviewRenderService] headless 渲染    | 整页 HTML         |
/// | getVerificationCode[usePhone]  | 弹对话框让用户填验证码                  | 验证码文本        |
/// | getWebViewUA                   | 读客户端 WebView 真实 UA                | UA 字符串         |
///
/// 全都经 `POST /savehtml` 回执。认不出的一律回空串放行 —— 后端拿不到结果
/// 最多是书源功能用不了，但绝不能让它干等 120s（整个书源 JS 线程被吊住）。
class BackendRequestHandler {
  BackendRequestHandler._();
  static final BackendRequestHandler instance = BackendRequestHandler._();

  static const Set<String> _handled = {
    'head', 'get', 'post',
    'webview',
    'getVerificationCode',
    'getVerificationCodeusePhone',
    'getWebViewUA',
  };

  static bool canHandle(String msg) => _handled.contains(msg);

  /// 处理并回执。fire-and-forget 调用 —— 内部不抛。
  Future<void> handle(WsPushMessage msg, String token) async {
    try {
      switch (msg.msg) {
        case 'webview':
          await WebviewRenderService.instance.handle(msg, token);
          return;
        case 'getVerificationCode':
        case 'getVerificationCodeusePhone':
          final code = await _askVerificationCode(msg);
          await _reply(token, msg.id, code);
          return;
        case 'getWebViewUA':
          final ua = await WebviewRenderService.instance.webViewUserAgent();
          await _reply(token, msg.id, ua);
          return;
        default:
          if (BackendProxyService.canHandle(msg.msg)) {
            await BackendProxyService.instance.handle(msg, token);
          } else {
            await _reply(token, msg.id, '');
          }
      }
    } catch (_) {
      // 任何漏网异常都不能漏掉回执
      await _reply(token, msg.id, '');
    }
  }

  Future<void> _reply(String token, String id, String html) async {
    if (id.isEmpty || token.isEmpty) return;
    try {
      await ApiService.instance.saveHtml(token, id: id, html: html);
    } catch (_) {}
  }

  /// 弹验证码输入框。`url` 非空时是验证码图片地址（图片验证码）；
  /// usePhone 变体通常没图，是短信验证码，只展示输入框。
  Future<String> _askVerificationCode(WsPushMessage msg) async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return '';
    final controller = TextEditingController();
    final imageUrl = msg.url.trim();
    final result = await showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(msg.title.trim().isNotEmpty ? msg.title.trim() : '输入验证码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (imageUrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Image.network(
                  imageUrl,
                  height: 48,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text(
                    '验证码图片加载失败',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(dialogCtx).colorScheme.error,
                    ),
                  ),
                ),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '验证码',
              ),
              onSubmitted: (v) => Navigator.of(dialogCtx).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(''),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result ?? '';
  }
}
