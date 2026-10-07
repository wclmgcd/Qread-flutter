import 'dart:async';

import 'package:flutter/services.dart';

/// 一个从外部（文件管理器 / 分享）传进来的文件。
class OpenedFile {
  const OpenedFile({required this.name, required this.content});

  /// 文件名，用来在界面上告诉用户「在导入哪个文件」。
  final String name;

  /// 文件的全部文本内容（UTF-8）。
  final String content;

  static OpenedFile? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    final content = raw['content']?.toString();
    if (content == null || content.trim().isEmpty) return null;
    return OpenedFile(
      name: (name == null || name.isEmpty) ? '导入.json' : name,
      content: content,
    );
  }
}

/// 接收「用其他应用打开 / 分享到 Qread」传进来的文件。
///
/// 【它解决什么问题】
/// 用户从聊天软件或文件管理器拿到一个书源 json，点「用其他应用打开」时，
/// 列表里要出现 Qread，并且选中后要**真的把那个文件导进去**。
/// 前半件事靠 Manifest / Info.plist 的 intent-filter（见
/// `android/app/src/main/AndroidManifest.xml` 与 `ios/Runner/Info.plist`），
/// 后半件就是这里 —— 接住原生侧传来的文件内容并广播出去。
///
/// 【协议】（两端原生实现完全一致，所以这份代码两端通用）
///   Dart → 原生：`getInitialFile`  取「冷启动时带进来的那个文件」
///   原生 → Dart：`onFileOpened`    推「热启动时进来的文件」
///
/// 【为什么冷启动要 Dart 主动取、热启动却是原生推】
/// 冷启动时原生先拿到文件、Flutter 引擎还没起来，原生没地方推，只能攒着等
/// Dart 来取；热启动时 Dart 已经在跑，原生直接推更快。
/// 两端（Kotlin / Swift）都做了「推失败就退回攒着」的兜底，
/// 所以 [pollInitialFile] 在 App 恢复前台时再调一次是安全的。
class FileOpenService {
  FileOpenService._();

  static final FileOpenService instance = FileOpenService._();

  static const MethodChannel _channel = MethodChannel('qread/file_open');

  final StreamController<OpenedFile> _controller =
      StreamController<OpenedFile>.broadcast();

  /// 收到的文件流。多次订阅安全（broadcast）。
  Stream<OpenedFile> get files => _controller.stream;

  bool _initialized = false;

  /// 挂上原生回调，并把「冷启动带进来的文件」取出来。
  ///
  /// 重复调用是幂等的（只会真正执行一次）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened') {
        final file = OpenedFile.fromPlatform(call.arguments);
        if (file != null) _controller.add(file);
      }
      return null;
    });

    await pollInitialFile();
  }

  /// 主动向原生要一次「还攒着的文件」。
  ///
  /// 冷启动时调一次即可；另外在 App 恢复前台时也调一次 ——
  /// 原生推给 Dart 时若 Dart 的 handler 还没注册好，那个文件会被原生退回
  /// 待取状态，靠这一次补取拿回来。
  Future<void> pollInitialFile() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('getInitialFile');
      final file = OpenedFile.fromPlatform(raw);
      if (file != null) _controller.add(file);
    } on MissingPluginException {
      // 平台没实现这个通道（桌面 / Web / 单元测试环境）—— 静默即可
    } on PlatformException {
      // 原生读文件失败（权限、URI 失效等），原生侧已经吞过异常了，
      // 这里再兜一层，避免把启动流程带崩
    }
  }
}
