import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/cookie_sync_service.dart';
import '../../widgets/adaptive_webview.dart';

class WebViewLoginPageArgs {
  final String sourceUrl;
  final String sourceName;
  final String type;
  final String loginUrl;
  final Map<String, String> headers;

  const WebViewLoginPageArgs({
    required this.sourceUrl,
    required this.sourceName,
    required this.type,
    required this.loginUrl,
    required this.headers,
  });
}

class WebViewLoginPage extends StatefulWidget {
  final WebViewLoginPageArgs args;

  const WebViewLoginPage({Key? key, required this.args}) : super(key: key);

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends State<WebViewLoginPage> {
  bool _completing = false;

  bool get _isBookSource => widget.args.type == 'bookSource';

  Future<void> _completeLogin() async {
    setState(() => _completing = true);
    try {
      final api = ApiService.instance;
      final token = context.read<UserProvider>().token ?? '';

      // 【关键】先把 WebView 里的 cookie 推给服务端，再触发 login()。
      // 网页登录是在**客户端 WebView** 里完成的，cookie 落在 WebView；
      // 而书源 `login()` 里的 `cookie.getCookie(url)` 读的是**服务端**的
      // CookieStore。中间不搬一次，后端就是「用户明明登录成功了，
      // 取用户信息却还是未登录」—— 这正是用户反馈的「cookie 没有同步过来」。
      // 官方 3.41 的顺序也是「WebView 登录 → 存 cookie → 再跑 login()」。
      // 按站点去重后逐个同步：bookSourceUrl 是书源标识、loginUrl 才是真正
      // 被登录的页面，两者偶尔不同子域（www.qidian.com / passport.qidian.com），
      // 但同属一个可注册域名，去重后只跑一次。
      final seen = <String>{};
      for (final url in [widget.args.sourceUrl, widget.args.loginUrl]) {
        final site = CookieSyncService.registrableDomain(url);
        if (site.isEmpty || !seen.add(site)) continue;
        await CookieSyncService.instance.syncOne(token, url);
      }

      if (_isBookSource) {
        // Trigger login() JS on backend
        await api.putSourcesLoginInfo(token, widget.args.sourceUrl, '{}');
      } else {
        // RSS: save empty login info to trigger cookie capture, then run login
        await api.putRssLoginInfo(token, widget.args.sourceUrl, '{}');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录完成')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录验证失败: $e')),
        );
        setState(() => _completing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('网页登录 - ${widget.args.sourceName}'),
        actions: [
          _completing
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                )
              : TextButton.icon(
                  icon: const Icon(Icons.check, color: Colors.white),
                  label: const Text('完成登录',
                      style: TextStyle(color: Colors.white)),
                  onPressed: _completeLogin,
                ),
        ],
      ),
      body: AdaptiveWebView(
        url: widget.args.loginUrl,
        enableJs: true,
        headers: widget.args.headers,
        onCustomScheme: (url) async {
          // Handle yuedu:// or legado:// import during login
        },
      ),
    );
  }
}
