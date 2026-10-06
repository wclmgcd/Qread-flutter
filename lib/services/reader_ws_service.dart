import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';

/// 后端通过 WebSocket 主动推给客户端的一条消息。
///
/// 对应后端 `book.app.WebMessage` / `book.app.ToastMessage`。阅读相关的几种：
/// - `startBrowserdp` / `startBrowser`：让客户端打开一个网页
///   （段评就走这条，`title` 一般是「段评」）；
/// - `toast` / `longToast`：让客户端弹提示（正文在 [str] 里）；
/// - `upLoginData` / `copyText` / `noticy`：书源 JS 回传的结果；
/// - `openurl` / `searchBook` / `addBook`：其它交互。
///
/// 【注意 [str] 与 [title] 是两套字段】
/// `ToastMessage(msg, str)` 用的是 **`str`**（后端 `App.toast` / `App.longToast` /
/// `App.log` 都走它）；`WebMessage` 那一族才用 `title`/`body`。
/// 早期版本这里只解析了 `title`/`body`，于是 `java.longToast(...)` 推来的内容
/// 解析出来永远是空串、被当成「没有内容」丢掉 —— 表现就是书源登录页里
/// 点任何按钮都毫无反应（那些按钮的结果全靠 `longToast` 报）。
class WsPushMessage {
  const WsPushMessage({
    required this.msg,
    this.url = '',
    this.title = '',
    this.header = '',
    this.html = '',
    this.body = '',
    this.str = '',
    this.id = '',
  });

  final String msg;
  final String url;
  final String title;
  final String header;
  final String html;
  final String body;

  /// `ToastMessage.str` —— toast / longToast / log 的正文
  final String str;
  final String id;

  /// 是否是「打开网页」类消息（段评 / 登录页 / 验证码页都走这类）
  bool get isOpenPage =>
      msg == 'startBrowserdp' || msg == 'startBrowser' || msg == 'showBrowser';

  /// header 是后端给的 JSON 字符串，解析成 Map 失败时返回空表
  Map<String, String> get headerMap {
    if (header.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(header);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
    } catch (_) {}
    return const {};
  }

  static WsPushMessage? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return WsPushMessage(
          msg: (decoded['msg'] ?? '').toString(),
          url: (decoded['url'] ?? '').toString(),
          title: (decoded['title'] ?? '').toString(),
          header: (decoded['header'] ?? '').toString(),
          html: (decoded['html'] ?? '').toString(),
          body: (decoded['body'] ?? '').toString(),
          str: (decoded['str'] ?? '').toString(),
          id: (decoded['id'] ?? '').toString(),
        );
      }
    } catch (_) {}
    return null;
  }
}

/// 阅读器用的后端长连接。
///
/// 轻阅读后端把「书源里跑的 JS 想跟用户交互」这件事做成了推送：
/// 书源调用 `java.startBrowserDp(url, title)`（段评专用）或 `java.startBrowser`，
/// 后端就把消息推给当前登录的客户端，由客户端打开对应网页。
///
/// 端点：`{apiBase}/ws?id={accessToken}`
class ReaderWsService {
  ReaderWsService._();

  static final ReaderWsService instance = ReaderWsService._();

  WebSocket? _socket;
  String? _token;
  bool _enabled = false;
  int _retryCount = 0;
  Timer? _reconnectTimer;
  bool _connecting = false;

  final StreamController<WsPushMessage> _pushController =
      StreamController<WsPushMessage>.broadcast();

  final StreamController<WsPushMessage> _toastController =
      StreamController<WsPushMessage>.broadcast();

  /// 后端推过来的消息流（多订阅者）
  Stream<WsPushMessage> get pushStream => _pushController.stream;

  /// `toast` / `longToast` 提示流（多订阅者）。
  ///
  /// 与 [onToast] 的区别：那个是**单槽位**回调，阅读页占了之后别的页面就收不到；
  /// 登录页同样需要接书源 JS 的提示（书源按钮的结果全靠 `java.longToast` 报），
  /// 所以另开一条广播流。两者会同时收到，互不影响。
  Stream<WsPushMessage> get toastStream => _toastController.stream;

  /// 需要弹提示时回调（由页面注册）
  void Function(String message)? onToast;

  bool get isConnected =>
      _socket != null && _socket!.readyState == WebSocket.open;

  /// 建立长连接（重复调用是安全的）
  Future<void> connect(String? token) async {
    if (token == null || token.isEmpty) return;
    if (_enabled && _token == token) return;
    _enabled = true;
    _token = token;
    await _open();
  }

  Future<void> _open() async {
    if (_connecting || !_enabled) return;
    final token = _token;
    if (token == null || token.isEmpty) return;
    _connecting = true;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;

    try {
      final socket = await WebSocket.connect(_wsUrl(token))
          .timeout(const Duration(seconds: 15));
      _socket = socket;
      _retryCount = 0;
      socket.listen(
        (data) {
          final text = data is String ? data : utf8.decode(data as List<int>);
          for (final line in text.split('\n')) {
            final message = WsPushMessage.tryParse(line);
            if (message == null) continue;
            if (message.msg == 'toast' || message.msg == 'longToast') {
              // 正文在 `str`（后端 ToastMessage），不是 title/body
              final tip = message.str.trim();
              if (!_toastController.isClosed) _toastController.add(message);
              if (tip.isNotEmpty) onToast?.call(tip);
              continue;
            }
            if (!_pushController.isClosed) _pushController.add(message);
          }
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _scheduleReconnect() {
    if (!_enabled) return;
    _reconnectTimer?.cancel();
    _retryCount = _retryCount.clamp(0, 6);
    final seconds = (3 * (1 << _retryCount)).clamp(3, 60);
    _retryCount++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      if (_enabled) _open();
    });
  }

  /// 主动断开并停止重连
  Future<void> disconnect() async {
    _enabled = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryCount = 0;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  void dispose() {
    disconnect();
    _pushController.close();
    _toastController.close();
  }

  String _wsUrl(String token) {
    final base = AppConstants.apiBase;
    final uri = Uri.parse(base);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final port = uri.hasPort ? ':${uri.port}' : '';
    final basePath = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    // sg=1：告诉后端「本端能显示长提示」。后端 `App.longToast` 会看这个标记，
    // 不带它就把 longToast 降级成普通 toast（见 InitConfig 里 `if(socket.sg)`），
    // 客户端也就分不出「多行结果」和「一句提示」，没法用不同方式呈现。
    final query = Uri(queryParameters: {'id': token, 'sg': '1'}).query;
    return '$scheme://${uri.host}$port$basePath/ws?$query';
  }
}
