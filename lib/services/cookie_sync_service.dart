import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_service.dart';

/// 书源登录 Cookie 在「客户端 WebView」与「服务端 CookieStore」之间的搬运。
///
/// 【为什么需要搬】
/// 网页登录是在**客户端的 WebView** 里完成的，cookie 落在 WebView 的 cookie jar；
/// 而书源 `login()` 里的 `cookie.getCookie(url)` 读的是**服务端**的 CookieStore。
/// 中间不搬一次，后端就是「用户明明登录成功了，取用户信息却是未登录」。
/// 官方 3.41 的流程也是「WebView 登录 → 存 cookie → 再跑 login()」，顺序不能反。
///
/// 【为什么是「按站点」而不是「整表」】
/// 早先这里用的是后端自加的 `/getAllCookies`、`/saveAllCookies`（整表搬运），
/// 但那两个接口**上游没有** —— 一用，这个 app 就只能连改过的后端了。
/// 上游本来就有按 url 读写的一对接口，栖阅、轻阅时光用的都是它们：
///
///   读：`GET  /getCookies?url=`  → `EncryptUtils.aesEncode` 出来的 hex
///   写：`POST /saveCookies?url=&cookie=` → 入参同样是 hex（服务端先解密再落盘）
///
/// 所以这里改用上游那一对，AES 由 [AesCodec] 在客户端做掉。代价是没法一次
/// 搬完整张表，得逐个站点来 —— 但后端 CookieStore 的落盘 key 本来就是
/// **站点的可注册域名**（`NetworkUtils.getSubDomain`，`www.qidian.com` →
/// `qidian.com`），而书源的 `bookSourceUrl` 就在同一个站点上，所以按书源逐个
/// 同步是够用的。
///
/// 【冲突策略：以客户端为准】
/// - 本地 WebView 里**有**这个站点的 cookie → 用本地的覆盖服务端（本地是新登录的）；
/// - 本地没有、服务端有 → 把服务端的写回本地 WebView（换设备/重装后恢复登录态）。
class CookieSyncService {
  CookieSyncService._();
  static final CookieSyncService instance = CookieSyncService._();

  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  /// 单个书源的一次同步：本地有就推上去，本地没有就把服务端的拉下来。
  ///
  /// [url] 传 `bookSourceUrl` 或 `loginUrl` 都行 —— 只要跟要登录的站点同域。
  /// 登录页进入前、登录完成后各调一次：前者让用户不必重复登录，后者保证
  /// 紧随其后的 `login()` 能读到刚拿到的 cookie。
  Future<void> syncOne(String accessToken, String url) async {
    if (accessToken.isEmpty || url.trim().isEmpty) return;
    try {
      final local = await _readLocal(url);
      if (local.isNotEmpty) {
        await ApiService.instance.saveCookies(accessToken, url, _join(local));
        return;
      }
      final remote = await ApiService.instance.getCookies(accessToken, url);
      if (remote.trim().isEmpty) return;
      await _writeLocal(url, remote);
    } catch (e) {
      debugPrint('cookie 同步失败($url): $e');
    }
  }

  /// 批量**只推不拉**：把本地 WebView 里已经存在的 cookie 推到服务端。
  ///
  /// 为什么不拉：每个站点一次 HTTP，几百个书源就是几百次请求，列表一加载
  /// 就打满网络。而「拉」的场景（换设备后恢复登录态）由 [syncOne] 在用户
  /// 真正打开某个书源的登录页时按需完成，体验上没有差别。
  ///
  /// 读取本地 cookie 是平台通道调用、不走网络，所以这一步的开销只跟
  /// **去重后的站点数**有关；按可注册域名去重后通常远小于书源条数。
  Future<void> pushMany(String accessToken, Iterable<String> urls) async {
    if (accessToken.isEmpty) return;
    final sites = <String>{};
    for (final url in urls) {
      final site = registrableDomain(url);
      if (site.isNotEmpty) sites.add(site);
    }
    for (final site in sites) {
      try {
        // 批量阶段只探可注册域名这一个 host，不再逐个探完整 host
        final local = await _readLocal(site, probeFullHost: false);
        if (local.isEmpty) continue;
        await ApiService.instance.saveCookies(accessToken, site, _join(local));
      } catch (e) {
        debugPrint('cookie 推送失败($site): $e');
      }
    }
  }

  // ============================================================
  // 本地 WebView 读写
  // ============================================================

  /// 读本地 WebView 里某个站点的 cookie。
  ///
  /// 要探两个 host：WebView 里 **host-only cookie** 只对 `www.qidian.com`
  /// 生效，拿根域名 `qidian.com` 去查是查不到的；反过来根域名上的 cookie
  /// 又不会出现在完整 host 的查询结果里。两个都探、更具体的 host 后读，
  /// 这样同名 cookie 以更精确的那个为准。
  Future<Map<String, String>> _readLocal(
    String url, {
    bool probeFullHost = true,
  }) async {
    final merged = <String, String>{};
    final reg = registrableDomain(url);
    final host = hostOf(url);

    final probes = <String>[];
    if (reg.isNotEmpty) probes.add(reg);
    if (probeFullHost && host.isNotEmpty && host != reg) probes.add(host);

    for (final probe in probes) {
      for (final c in await _readCookies(probe)) {
        if (c.name.isEmpty || c.value.isEmpty) continue;
        merged[c.name] = c.value;
      }
    }
    return merged;
  }

  Future<List<WebViewCookie>> _readCookies(String host) async {
    try {
      return await _cookieManager.getCookies(domain: Uri.parse('https://$host'));
    } catch (e) {
      // Android 上是 `CookieManager.getCookie(url)`，非法/不存在的 host 会抛
      debugPrint('读取本地 cookie 失败($host): $e');
      return const [];
    }
  }

  /// 把服务端的 cookie 串写回本地 WebView。
  ///
  /// domain 用**可注册域名**：服务端就是按它存的，而且这样写进去的 cookie
  /// 对 `www.` / `passport.` 这些子域都生效 —— 书源的取数域名和登录域名
  /// 经常不是同一个子域。
  Future<void> _writeLocal(String url, String cookieString) async {
    final domain = registrableDomain(url);
    if (domain.isEmpty) return;
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

  static String _join(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  // ============================================================
  // 域名解析
  // ============================================================

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
