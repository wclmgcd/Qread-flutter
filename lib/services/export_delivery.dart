/// 「导出文件」该用哪种方式交给用户 —— **纯逻辑**，不依赖 Flutter。
///
/// 【为什么单独一个文件、还自己定义枚举】
/// 这个判断就是「导出按钮点了会报错」那次修复的核心，值得被逐条验证。
/// 但 `TargetPlatform` 是 Flutter 的，一 import 就进不了本地探针工程
/// （本机没有 Flutter SDK，见技能 `flutter-dart-local-validation` §8.5）。
/// 所以这里只认自己定义的 [ExportHost]，由调用方
/// （`export_file_saver.dart`）把 `kIsWeb` / `defaultTargetPlatform`
/// 翻译过来。于是 `bin/probe_cache.dart` 能把七种宿主全打一遍表。
library;

/// 运行环境。
///
/// 取值与 Flutter 的 `TargetPlatform` 一一对应，外加一个 [web]。
/// **刻意不复用 `TargetPlatform`** —— 保持本文件零 Flutter 依赖。
enum ExportHost {
  android,
  iOS,
  fuchsia,
  linux,
  macOS,
  windows,
  web,

  /// Flutter 将来新增的、本文件还不认识的平台。
  ///
  /// 【为什么需要它】`currentExportHost()` 要 switch Flutter 的
  /// `TargetPlatform`（外部枚举）。如果写成穷尽 switch、不留 `default`，
  /// 那么 Flutter 哪天真加了一个平台值，**编译期**就会失败 ——
  /// 一个和本项目毫无关系的依赖升级把 CI 打红。留一个兜底值之后，
  /// 新平台只会落到「不支持」，不会崩也不会编不过。
  unknown,
}

/// 最终把导出字节交给用户的方式。
enum ExportDelivery {
  /// 弹系统「另存为」对话框，直接写进用户选的路径。
  saveDialog,

  /// 交给系统分享面板（Android 的 `ACTION_SEND`、
  /// iOS 的 `UIActivityViewController`）。
  ///
  /// Android 上用户在面板里选「保存到文件」即可落盘 ——
  /// 这是移动端导出文件的标准做法，且不需要任何存储权限。
  shareSheet,

  /// 当前平台没有可用的落地方式，只能如实告诉用户。
  unsupported,
}

/// 按运行环境决定导出方式。
///
/// 【为什么移动端不能用「另存为」】
/// `file_selector` 的 `getSaveLocation()` 底层调 `getSavePath()`，
/// 官方支持表里 **Android / iOS / Web 三端都是 ❌**，调用会直接抛
/// ```
/// UnimplementedError: getSavePath() has not been implemented.
/// ```
/// 只有 Linux / macOS / Windows 支持（见 pub.dev/packages/file_selector
/// 的 "Features supported by platform" 一节）。
///
/// 之前「常规设置 → 缓存管理 → 导出」和「书架 → 保存到文件」都是无脑调
/// `getSaveLocation()`，所以**在 Android 上一点就报错**。移动端换成
/// 自建的分享通道之后，两个功能一起修好。
///
/// 【Web 为什么是不支持】
/// Web 端 `getSaveLocation` 同样是 ❌；要下载只能自己拼 `Blob` 走
/// `package:web`，而那会多一个条件导入分支。当前网页版的章节缓存本来就
/// 只存在内存里（`cache_store_web.dart`），刷新即失效，导出价值有限，
/// 所以先如实返回 [ExportDelivery.unsupported]，不假装能做。
/// 将来要补，加一个 `dart.library.js_interop` 条件导入的下载实现即可。
///
/// 【Fuchsia 为什么也算不支持】
/// 没有任何原生实现（本项目只有 android / ios 两套），归到不支持比
/// 归到分享面板更诚实。
///
/// 【[ExportHost.unknown] 同理】
/// 不认识的平台一律「不支持」—— 宁可如实说做不到，也不要假装弹了面板。
ExportDelivery resolveExportDelivery(ExportHost host) {
  switch (host) {
    case ExportHost.linux:
    case ExportHost.macOS:
    case ExportHost.windows:
      return ExportDelivery.saveDialog;
    case ExportHost.android:
    case ExportHost.iOS:
      return ExportDelivery.shareSheet;
    case ExportHost.fuchsia:
    case ExportHost.web:
    case ExportHost.unknown:
      return ExportDelivery.unsupported;
  }
}
