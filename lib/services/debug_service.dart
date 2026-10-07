import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/constants.dart';

/// 「书源调试 / 订阅源调试」用的长连接。
///
/// 【为什么用 WebSocketChannel 而不是 dart:io 的 WebSocket】
/// `dart:io` 在 Web 上不存在，直接用 `WebSocket.connect` 会让
/// `flutter build web` 编译期就失败。`web_socket_channel` 是 Dart 官方维护的
/// 跨平台封装：原生端底下就是 `dart:io` 的 WebSocket（行为不变），
/// Web 端换成浏览器的 `WebSocket`，我们这边只写一份代码。
class DebugService {
  WebSocketChannel? _socket;

  /// 连接是否已建立。`WebSocketChannel` 没有同步可读的 readyState，
  /// 只能自己记：在 `await ready` 成功、onDone、onError 三处维护。
  bool _connected = false;

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  bool _disposed = false;
  Completer<void>? _done;

  Stream<String> get logStream => _logController.stream;
  bool get isConnected => _connected;

  Future<void> startBookDebug({
    required String accessToken,
    required String sourceUrl,
    required String key,
  }) async {
    await _disconnect();
    _done = Completer<void>();

    final wsUrl = _wsUrl('/debug?id=$accessToken');
    try {
      final socket = await _connect(wsUrl);
      _socket = socket;
      _listen(socket);
      final msg = jsonEncode({'url': sourceUrl, 'key': key});
      socket.sink.add(msg);
    } catch (e) {
      _logController.add('连接失败: $e');
      _done?.completeError(e);
    }
  }

  Future<void> startRssDebug({
    required String accessToken,
    required String sourceUrl,
  }) async {
    await _disconnect();
    _done = Completer<void>();

    final wsUrl = _wsUrl('/rssdebug?id=$accessToken');
    try {
      final socket = await _connect(wsUrl);
      _socket = socket;
      _listen(socket);
      final msg = jsonEncode({'url': sourceUrl});
      socket.sink.add(msg);
    } catch (e) {
      _logController.add('连接失败: $e');
      _done?.completeError(e);
    }
  }

  /// 建连。`WebSocketChannel.connect` 是「立刻返回、后台去连」，
  /// 必须等 `ready` 才算真的连上（否则异常要等到 listen 之后才冒出来，
  /// 这里的 try/catch 就抓不到了）。
  Future<WebSocketChannel> _connect(String wsUrl) async {
    final socket = WebSocketChannel.connect(Uri.parse(wsUrl));
    await socket.ready;
    _connected = true;
    return socket;
  }

  void _listen(WebSocketChannel socket) {
    socket.stream.listen(
      (data) {
        if (_disposed) return;
        final text = data is String ? data : utf8.decode(data as List<int>);
        _parseAndEmit(text);
      },
      onDone: () {
        _connected = false;
        if (!_disposed) {
          _logController.add('--- 调试结束 ---');
          _done?.complete();
        }
      },
      onError: (error) {
        _connected = false;
        if (!_disposed) {
          _logController.add('连接错误: $error');
          _done?.completeError(error);
        }
      },
      cancelOnError: true,
    );
  }

  void _parseAndEmit(String text) {
    // WebSocket messages are newline-delimited JSON: {"msg":"..."}\n\n
    final lines = text.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final json = jsonDecode(trimmed);
        if (json is Map && json.containsKey('msg')) {
          _logController.add(json['msg'].toString());
        } else {
          _logController.add(trimmed);
        }
      } catch (_) {
        _logController.add(trimmed);
      }
    }
  }

  String _wsUrl(String path) {
    final base = AppConstants.apiBase;
    final uri = Uri.parse(base);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final host = uri.host;
    final port = uri.hasPort ? ':${uri.port}' : '';
    final basePath = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return '$scheme://$host$port$basePath$path';
  }

  Future<void> cancel() async {
    await _disconnect();
    _logController.add('--- 已取消 ---');
  }

  Future<void> _disconnect() async {
    if (_socket != null) {
      try {
        await _socket!.sink.close();
      } catch (_) {}
      _socket = null;
    }
    _connected = false;
    if (_done != null && !_done!.isCompleted) {
      _done!.complete();
    }
  }

  void dispose() {
    _disposed = true;
    _disconnect();
    _logController.close();
  }
}
