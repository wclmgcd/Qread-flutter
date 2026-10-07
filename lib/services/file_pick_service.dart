import 'package:flutter/services.dart';

/// 用户从系统文件选择器里挑中的一本本地书。
class PickedBookFile {
  const PickedBookFile({required this.path, required this.name});

  /// 文件在 App 私有目录里的**真实路径**。
  ///
  /// 原生侧已经把内容复制进来了（Android 从 `content://` 拷进 `cacheDir`，
  /// iOS 用 `.import` 模式让系统拷进沙盒），所以这里可以直接交给 dio 上传。
  final String path;

  /// 文件名（含后缀），用来判类型、也用来在后端落盘。
  final String name;

  static PickedBookFile? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path']?.toString();
    if (path == null || path.isEmpty) return null;
    final name = raw['name']?.toString();
    return PickedBookFile(
      path: path,
      name: (name == null || name.isEmpty) ? 'book' : name,
    );
  }
}

/// 调起系统文件选择器，让用户挑一本本地书。
///
/// 【它解决什么问题】
/// 书架的「添加本地」需要一个「从手机里选一个文件」的能力。
/// 系统选择器在两端都是原生 API，Flutter 没有内置，
/// 而引第三方插件（file_picker 等）要改 pubspec —— 本机没有 Flutter SDK，
/// 依赖解析无法本地验证，一旦解析失败就是 CI 红。
/// 这里自己开一个 MethodChannel，两端各几十行，可控。
///
/// 【协议】（两端原生实现完全一致，所以这份代码两端通用）
///   Dart → 原生：`pickBookFile` → {path, name}；用户取消时返回 null
///
/// 【和 FileOpenService 的区别】
/// FileOpenService 接的是「用户从别处点打开方式/分享进来」的文件，是被动的；
/// 这里是用户主动在 App 内点按钮去挑文件。两条链路最终都汇到同一个上传接口。
class FilePickService {
  FilePickService._();

  static final FilePickService instance = FilePickService._();

  static const MethodChannel _channel = MethodChannel('qread/file_pick');

  /// 打开系统文件选择器。
  ///
  /// 返回用户选中的文件；**用户取消时返回 null**（这不是错误，调用方应静默处理）。
  /// 平台没有实现这个通道时抛 [UnsupportedError]。
  Future<PickedBookFile?> pickBookFile() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('pickBookFile');
      return PickedBookFile.fromPlatform(raw);
    } on MissingPluginException {
      throw UnsupportedError('当前平台不支持选择本地文件');
    } on PlatformException catch (e) {
      throw Exception(e.message ?? '打开文件选择器失败');
    }
  }
}
