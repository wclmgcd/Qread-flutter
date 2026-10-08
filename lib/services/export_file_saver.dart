import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

import 'export_delivery.dart';

/// 「把文件交给系统分享面板」的通道。
///
/// 【对应关系】通道名 / 方法名 / 参数名与两端原生实现
/// （`android/.../MainActivity.kt`、`ios/Runner/AppDelegate.swift`）
/// **完全一致**，所以 Dart 这边一份代码两端通用 ——
/// 和本仓库既有的 `qread/file_open` / `qread/file_pick` /
/// `qread/system_ui` / `qread/dictionary` 四个通道同一个套路。
///
/// 【为什么不引第三方插件（如 share_plus）】
/// 和 `file_pick_service.dart` 里写的一样：引插件要改 pubspec，而本机没有
/// Flutter SDK、无法验证 pub 解析，一旦解析失败就是 CI 红。分享的逻辑两端
/// 各几十行，自己开通道更可控。
/// （另外 share_plus 12.0.0 起要求 AGP >= 8.12.1，而本仓库是 8.11.1 ——
/// 真要用还得连 Android 构建配置一起动。）
///
/// Dart → 原生：`shareFile({bytes, name, mimeType, title?})` → `bool`
///   返回 false 表示系统里没有任何 App 能接收这个文件。
const MethodChannel _shareChannel = MethodChannel('qread/share_file');

/// 把 `kIsWeb` / `defaultTargetPlatform` 翻译成纯 Dart 的 [ExportHost]。
///
/// 【为什么要有这一层】[resolveExportDelivery] 是纯逻辑、要被探针打表验证，
/// 所以它不认识 Flutter 的 `TargetPlatform`；Flutter 的枚举只在**这里**出现。
///
/// 【为什么必须留 default】`TargetPlatform` 是 Flutter 的外部枚举。穷尽 switch
/// 看起来很干净，但 Flutter 哪天真加一个平台值，**编译期**就会失败 ——
/// 一次和本项目无关的依赖升级把 CI 打红。留 default 之后新平台只会落到
/// [ExportHost.unknown]（→ 不支持），不会崩也不会编不过。
ExportHost currentExportHost() {
  if (kIsWeb) return ExportHost.web;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return ExportHost.android;
    case TargetPlatform.iOS:
      return ExportHost.iOS;
    case TargetPlatform.fuchsia:
      return ExportHost.fuchsia;
    case TargetPlatform.linux:
      return ExportHost.linux;
    case TargetPlatform.macOS:
      return ExportHost.macOS;
    case TargetPlatform.windows:
      return ExportHost.windows;
    default:
      return ExportHost.unknown;
  }
}

/// 把一份导出内容交给用户。
///
/// **用户取消返回 `null`**；成功则返回一句可以直接丢进 SnackBar 的文案。
///
/// 【两条路】
///   - 桌面（Linux / macOS / Windows）→ `getSaveLocation()` 弹「另存为」，
///     我们自己写盘，能拿到确切路径；
///   - Android / iOS → 把字节交给原生：写进缓存目录再经 FileProvider /
///     UIActivityViewController 弹系统分享面板。移动端**拿不到**用户最终
///     存到哪，所以返回的文案只说「已交给分享面板」。
///
/// 平台差异见 [resolveExportDelivery] 的注释。
Future<String?> deliverExport({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  required XTypeGroup typeGroup,
  String? shareTitle,
}) async {
  final host = currentExportHost();
  switch (resolveExportDelivery(host)) {
    case ExportDelivery.saveDialog:
      final location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: [typeGroup],
      );
      if (location == null) return null; // 用户取消了「另存为」
      await XFile.fromData(
        bytes,
        mimeType: mimeType,
        name: fileName,
      ).saveTo(location.path);
      return '已保存到 ${location.path}';

    case ExportDelivery.unsupported:
      // 网页版 / 未知平台。不是崩溃，给一句能看懂的话。
      return '当前平台暂不支持导出文件';

    case ExportDelivery.shareSheet:
      try {
        final shown = await _shareChannel.invokeMethod<bool>('shareFile', {
          'bytes': bytes,
          'name': fileName,
          'mimeType': mimeType,
          if (shareTitle != null) 'title': shareTitle,
        });
        if (shown != true) {
          return '系统里没有可以接收这个文件的应用';
        }
        return '已导出 $fileName，请在系统面板里选「保存到文件」或发送给其它应用';
      } on MissingPluginException {
        // 通道没实现（例如新平台）。不是崩溃，给一句能看懂的话。
        return '当前平台暂不支持导出文件';
      } on PlatformException catch (e) {
        throw Exception(e.message ?? '调起分享面板失败');
      }
  }
}
