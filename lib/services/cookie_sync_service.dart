import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_service.dart';

/// 书源登录 Cookie 的整表同步。
///
/// 【为什么是「整表」而不是按书源】
/// 后端 `CookieStore` 落盘的 key 是 `NetworkUtils.getSubDomain(被登录的页面 url)`
/// —— 也就是目标站点的**可注册域名**（`www.qidian.com` → `qidian.com`），
/// 与「哪个书源」无关：一个书源可能登录多个站点，多个书源也可能共用同一个站点。
/// 所以按书源逐个查根本无从下手，只能整张表搬。后端为此专门开了
/// `/getAllCookies`（拉）和 `/saveAllCookies`（推），但本 Flutter 客户端
/// 一直没接 —— 用户反馈「书源的同步有问题，好像 cookie 没有同步过来」。
///
/// 【为什么登录后必须马上同步】
/// 网页登录是在**客户端的 WebView** 里完成的，cookie 落在 WebView 里；
/// 而书源 `login()` 里的 `cookie.getCookie(url)` 读的是**服务端**的 CookieStore。
/// 中间不搬一次，后端就是「用户明明登录成功了，取用户信息却是未登录」。
/// 官方 3.41 的流程也是「WebView 登录 → 存 cookie → 再跑 login()」，顺序不能反。
///
/// 【冲突策略：以客户端为准】
/// - 本地 WebView 里**有**这个域名的 cookie → 用本地的覆盖服务端（本地是新登录的）；
/// - 本地没有、服务端有 → 把服务端的写回本地 WebView（换设备/重装后恢复登录态）。
class CookieSyncService {
  CookieSyncService._();
  static final CookieSyncService instance = CookieSyncService._();

  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  /// 双向同步一次。
  ///
  /// [urls] 是「书源站点」的地址（`bookSourceUrl` / `loginUrl` 都行），
  /// 用来补上服务端还没有、但客户端可能刚登录过的域名。
  Future<void> sync(
    String accessToken, {
    Iterable<String> urls = const [],
  }) async {
    if (accessToken.isEmpty) return;
    try {
      final serverCookies = await ApiService.instance.getAllCookies(accessToken);

      // 可注册域名 → 需要去 WebView 里探测的 host 列表。
      // 先放可注册域名本身（如 qidian.com），再放完整 host（如 www.qidian.com）：
      // 后读到的覆盖先读到的，所以更具体的 host 优先级更高 —— WebView 里
      // host-only cookie 只对 www.qidian.com 生效，用根域名去查是查不到的。
      final probes = <String, LinkedHashSet<String>>{};

      void addProbe(String url) {
        final host = hostOf(url);
        if (host.isEmpty) return;
        final reg = registrableDomain(host);
        if (reg.isEmpty) return;
        final set = probes.putIfAbsent(reg, LinkedHashSet<String>.new);
        set.add(reg);
        set.add(host);
      }

      for (final url in urls) {
        addProbe(url);
      }
      for (final domain in serverCookies.keys) {
        final set = probes.putIfAbsent(domain, LinkedHashSet<String>.new);
        set.add(domain);
      }
      if (probes.isEmpty) return;

      final upload = <String, String>{};
      for (final entry in probes.entries) {
        final domain = entry.key;
        final merged = <String, String>{};
        for (final host in entry.value) {
          for (final c in await _readCookies(host)) {
            if (c.name.isEmpty || c.value.isEmpty) continue;
            merged[c.name] = c.value;
          }
        }

        if (merged.isNotEmpty) {
          // 客户端本来就有的域名 → 以客户端为准
          upload[domain] = merged.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; ');
        } else {
          final remote = serverCookies[domain];
          if (remote != null && remote.isNotEmpty) {
            await _writeLocal(domain, remote);
          }
        }
      }

      if (upload.isNotEmpty) {
        await ApiService.instance.saveAllCookies(accessToken, upload);
      }
    } catch (e) {
      debugPrint('cookie 同步失败: $e');
    }
  }

  /// 读本地 WebView 里某个 host 的 cookie
  Future<List<WebViewCookie>> _readCookies(String host) async {
    try {
      return await _cookieManager.getCookies(domain: Uri.parse('https://$host'));
    } catch (e) {
      // Android 上是 `CookieManager.getCookie(url)`，非法/不存在的 host 会抛
      debugPrint('读取本地 cookie 失败($host): $e');
      return const [];
    }
  }

  /// 把服务端的 cookie 串写回本地 WebView
  Future<void> _writeLocal(String domain, String cookieString) async {
    for (final pair in cookieString.split(';')) {
      final i = pair.indexOf('=');
      if (i <= 0) continue;
      final name = pair.substring(0, i).trim();
      final value = pair.substring(i + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      try {
        await _cookieManager.setCookie(
          WebViewCookie(name: name, value: value, domain: domain),
        );
      } catch (_) {
        // 个别域名/属性不被 WebView 接受时跳过即可，不要中断整轮同步
      }
    }
  }

  /// 常见二级后缀 —— 这些后缀的「可注册域名」要再往左取一段。
  static const Set<String> _twoLevelTlds = {
    'com.cn', 'net.cn', 'org.cn', 'gov.cn', 'edu.cn', 'ac.cn',
    'com.tw', 'org.tw', 'net.tw', 'com.hk', 'org.hk', 'com.mo',
    'co.jp', 'ne.jp', 'or.jp', 'co.kr', 'com.au', 'co.uk',
  };

  /// 从 URL 或裸 host 里取出 host（统一小写、去掉端口）。
  ///
  /// 不能只用 `Uri.parse(url).host`：书源里的 `bookSourceUrl` 偶尔是没带
  /// scheme 的裸域名，这时 Uri 会把它当成 path，`host` 是空的。
  static String hostOf(String hostOrUrl) {
    var host = Uri.tryParse(hostOrUrl)?.host ?? '';
    if (host.isEmpty) {
      host = hostOrUrl.contains('://') ? '' : hostOrUrl;
    }
    host = host.trim().toLowerCase();
    if (host.isEmpty) return '';
    final slash = host.indexOf('/');
    if (slash > 0) host = host.substring(0, slash);
    // 带端口（如 127.0.0.1:8080）
    final colon = host.indexOf(':');
    if (colon > 0) host = host.substring(0, colon);
    return host;
  }

  /// 取可注册域名，对齐后端 `PublicSuffixDatabase.getEffectiveTldPlusOne`。
  ///
  /// 只是个近似实现（没带公共后缀表），但覆盖了书源实际会遇到的域名形态；
  /// 万一算错，最坏结果是这个域名的 cookie 同步不到，不影响其它域名。
  static String registrableDomain(String hostOrUrl) {
    final host = hostOf(hostOrUrl);
    if (host.isEmpty) return '';
    // IP 直连：后端也直接返回 host
    if (RegExp(r'^\d+(\.\d+){3}$').hasMatch(host)) return host;
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    final last2 = '${parts[parts.length - 2]}.${parts[parts.length - 1]}';
    if (_twoLevelTlds.contains(last2)) {
      return '${parts[parts.length - 3]}.$last2';
    }
    return last2;
  }
}
