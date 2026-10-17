import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'cookie_sync_service.dart';
import 'reader_ws_service.dart';

/// 后端让客户端代发 HTTP 请求（head/get/post）的处理器。
///
/// 【这条链路是什么】
/// 书源 JS 里的 `java.head(url, header)` / `java.get(url, header)` /
/// `java.post(url, body, header)` 有一个"客户端代理"形态：后端不自己发请求，
/// 而是把参数通过 WebSocket 推给客户端，让**客户端**用本地网络发，再把响应
/// 回传。触发条件是书源 JS 显式调用带 client 代理语义的 `java.ajax` 系列
/// （read 后端 `InitConfig.kt` 的 `App.head/get/post`）。
///
/// 为什么书源要这么干：有些站点认客户端 IP、或要 WebView 里的登录态，
/// 服务端直连会被拒。客户端代理把"出口"换成了用户手机。
///
/// 【协议形状】
/// - 推送：WebMessage，`msg` = "head"/"get"/"post"，`url` 目标地址，
///   `header` 是 JSON 字符串（Map<String,String>），`body` 仅 post 用，
///   `title` 是 `"$move"`（跟随重定向）或 `"$no$move$"`（不跟随），
///   `id` 是回执 id。
/// - 回执：`POST /savehtml`，`id` + `html` = **MyResponse 的 JSON 串**。
///   MyResponse 的 `body` 字段是**原始响应字节的 Base64**（不是文本），
///   服务端按 content-type 的 charset 解码（见后端 JsonpResponse.kt）。
///
/// 【cookie 从哪来】
/// 调用方（书源 JS）给的 header 里通常**不带** Cookie —— 登录态在客户端
/// WebView 的 cookie jar 里。所以这里会从 CookieSyncService 读本地 cookie
/// 补上；调用方显式给了 Cookie 头则以调用方为准。
class BackendProxyService {
  BackendProxyService._();
  static final BackendProxyService instance = BackendProxyService._();

  static const Set<String> proxyMethods = {'head', 'get', 'post'};

  static bool canHandle(String msg) => proxyMethods.contains(msg);

  /// 执行代理请求并回执。
  ///
  /// 永远不抛：任何失败（网络错、超时、解析错）都回一个 403 形状的空响应，
  /// 让后端的 `WaitForResponse` 立刻放行，书源 JS 拿到失败状态自己处理。
  /// 这是官方客户端的行为 —— 干等 120s 超时比立刻报失败体验差得多。
  Future<void> handle(WsPushMessage msg, String token) async {
    try {
      final response = await _execute(msg);
      await _reply(token, msg.id, jsonEncode(response));
    } catch (e) {
      debugPrint('客户端代理请求失败(${msg.url}): $e');
      await _reply(token, msg.id, jsonEncode(_errorResponse(msg, e)));
    }
  }

  Future<Map<String, dynamic>> _execute(WsPushMessage msg) async {
    final method = msg.msg.toUpperCase();
    final url = msg.url.trim();
    if (url.isEmpty) return _errorResponse(msg, 'empty url');

    // 跟随重定向：title="$move" 跟随，"$no$move$" 不跟随，缺省跟随。
    final followRedirects = msg.title != r'$no$move$';

    final headers = <String, String>{};
    msg.headerMap.forEach((k, v) => headers[k] = v);

    // 补本地 WebView cookie（调用方没给的话）。
    if (!kIsWeb && !headers.keys.any((k) => k.toLowerCase() == 'cookie')) {
      try {
        final local = await CookieSyncService.instance.readLocalJoined(url);
        if (local.isNotEmpty) headers['Cookie'] = local;
      } catch (_) {}
    }

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: followRedirects,
      maxRedirects: followRedirects ? 5 : 0,
      // 任何状态码都当成功返回 —— 404/500 也是"响应"，要原样回给后端。
      validateStatus: (_) => true,
      responseType: ResponseType.bytes,
    ));
    try {
      final resp = await dio.request<List<int>>(
        url,
        data: method == 'POST' ? msg.body : null,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.bytes,
          followRedirects: followRedirects,
          maxRedirects: followRedirects ? 5 : 0,
          validateStatus: (_) => true,
        ),
      );
      final respHeaders = <String, List<String>>{};
      resp.headers.forEach((name, values) {
        respHeaders[name] = values;
      });
      final bodyBytes = resp.data ?? const <int>[];
      return {
        // realUri：跟随重定向后的最终地址；后端拿它做相对链接解析。
        'url': resp.realUri.toString(),
        'method': method,
        'headers': respHeaders,
        'body': base64Encode(bodyBytes),
        'statusCode': resp.statusCode ?? 0,
        'statusMessage': resp.statusMessage ?? '',
      };
    } finally {
      dio.close();
    }
  }

  Map<String, dynamic> _errorResponse(WsPushMessage msg, Object e) => {
        'url': msg.url,
        'method': msg.msg.toUpperCase(),
        'headers': <String, List<String>>{},
        'body': '',
        'statusCode': 403,
        'statusMessage': e.toString(),
      };

  Future<void> _reply(String token, String id, String html) async {
    if (id.isEmpty || token.isEmpty) return;
    try {
      await ApiService.instance.saveHtml(token, id: id, html: html);
    } catch (e) {
      debugPrint('代理回执失败: $e');
    }
  }
}
