import 'dart:async';

import 'package:flutter/services.dart';

/// 一个从外部（文件管理器 / 分享）传进来的文件。
class OpenedFile {
  const OpenedFile({
    required this.name,
    required this.content,
    this.path,
  });

  /// 文件名，用来在界面上告诉用户「在导入哪个文件」。
  final String name;

  /// 文件的全部文本内容（UTF-8）。
  ///
  /// 只对**纯文本**文件有意义（书源 json、txt 书源）。
  /// 二进制书籍（epub / mobi）读不出文本，这里是空串 —— 那种文件走 [path]。
  final String content;

  /// 文件在 App 私有目录里的真实路径。
  ///
  /// 【为什么需要它】
  /// epub / mobi 是二进制格式，`String(data:encoding:.utf8)` 直接失败。
  /// 所以原生侧对这类文件改走「复制一份到缓存目录、把路径传过来」，
  /// Dart 侧再拿这个路径上传给后端解析。
  /// 书源 json 这类纯文本文件也会带上它（txt 可能需要当小说上传），但没有也不影响。
  final String? path;

  /// 是不是一本「电子书」，而不是书源 / 订阅源文件。
  ///
  /// 只按后缀判断 epub / mobi 家族；`.txt` 有歧义（既可能是书源文本，
  /// 也可能是小说），交给 [looksLikeSourceJson] 按内容再判一次。
  bool get isBinaryBook {
    final lower = name.toLowerCase();
    return lower.endsWith('.epub') ||
        lower.endsWith('.mobi') ||
        lower.endsWith('.azw') ||
        lower.endsWith('.azw3') ||
        lower.endsWith('.prc');
  }

  bool get isTxt => name.toLowerCase().endsWith('.txt');

  /// 内容看起来是不是书源 / 订阅源 JSON（以 `[` 或 `{` 开头）。
  bool get looksLikeSourceJson {
    final trimmed = content.trimLeft();
    return trimmed.startsWith('[') || trimmed.startsWith('{');
  }

  static OpenedFile? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    final content = raw['content']?.toString();
    final path = raw['path']?.toString();
    final hasContent = content != null && content.trim().isNotEmpty;
    final hasPath = path != null && path.isNotEmpty;
    // 二进制书籍只有 path、没有 content，所以两者有一个就算有效
    if (!hasContent && !hasPath) return null;
    return OpenedFile(
      name: (name == null || name.isEmpty) ? '导入文件' : name,
      content: content ?? '',
      path: hasPath ? path : null,
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
