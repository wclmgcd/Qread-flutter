import 'dart:async';

import 'package:flutter/material.dart';

import '../config/routes.dart';
import '../pages/bookshelf/local_book_import_page.dart';
import '../pages/source/file_import_page.dart';
import '../services/file_open_service.dart';

/// 监听「用其他应用打开 / 分享到 Qread」传进来的文件，并弹出导入界面。
///
/// 挂在 `MaterialApp.builder` 上（包住 Navigator），这样**任何页面**
/// 都能被外部打开的文件打断 —— 用户在书架、在阅读页、在设置里，
/// 从文件管理器打开一个书源 json，都应该能直接导入。
///
/// 【为什么不用 context 拿 Navigator】
/// `builder` 的 context 在 Navigator 之上，`Navigator.of(context)` 拿不到。
/// 所以统一走全局的 [appNavigatorKey]。
class FileOpenListener extends StatefulWidget {
  const FileOpenListener({Key? key, required this.child}) : super(key: key);

  final Widget child;

  @override
  State<FileOpenListener> createState() => _FileOpenListenerState();
}

class _FileOpenListenerState extends State<FileOpenListener>
    with WidgetsBindingObserver {
  StreamSubscription<OpenedFile>? _subscription;

  /// 已经有一个导入页在弹了 —— 避免连点两次「打开方式」弹出两层。
  bool _showing = false;

  /// 冷启动极早期 Navigator 还没建好时的重试次数上限，
  /// 避免 key 一直拿不到时无限排帧。
  int _retries = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = FileOpenService.instance.files.listen(_handleFile);
    // 冷启动带进来的文件在这一步被取出来
    FileOpenService.instance.init();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 兜底：原生往 Dart 推文件时，若 Dart 侧的 handler 还没注册好，
    // 那个文件会被原生退回「待取」状态。回到前台时补取一次。
    if (state == AppLifecycleState.resumed) {
      FileOpenService.instance.pollInitialFile();
    }
  }

  void _handleFile(OpenedFile file) {
    if (!mounted || _showing) return;

    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      // 冷启动时文件可能比第一帧到得还早。等一帧再试，最多试 10 帧。
      if (_retries >= 10) {
        _retries = 0;
        return;
      }
      _retries++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleFile(file));
      return;
    }
    _retries = 0;

    _showing = true;
    navigator
        .push(_routeFor(file))
        .whenComplete(() => _showing = false);
  }

  /// 按文件类型决定弹哪个导入页。
  ///
  /// 【为什么要分流】
  /// 「打开方式」进来的可能是**书源 JSON**（文本，走 FileImportPage），
  /// 也可能是**一本电子书**（epub / mobi，二进制，只能上传给后端解析）。
  /// 前者读的是字符串，后者读的是文件路径，两条链路完全不同。
  ///
  /// 【`.txt` 为什么按内容再判一次】
  /// txt 有两种身份：书源可以存成纯文本分享，小说也是 txt。
  /// 内容以 `[` / `{` 开头就当归书源，否则当小说走上传。
  MaterialPageRoute<bool> _routeFor(OpenedFile file) {
    if (_isLocalBook(file)) {
      return MaterialPageRoute<bool>(
        builder: (_) => LocalBookImportPage(file: file),
        fullscreenDialog: true,
      );
    }
    return MaterialPageRoute<bool>(
      builder: (_) => FileImportPage(file: file),
      fullscreenDialog: true,
    );
  }

  bool _isLocalBook(OpenedFile file) {
    // epub / mobi / azw / azw3 / prc：没有歧义，一定是书
    if (file.isBinaryBook) return true;
    // 内容像书源 JSON：交给书源导入页
    if (file.looksLikeSourceJson) return false;
    // 剩下的只可能是 txt 小说；没有路径就没法上传，仍交给书源页去报错
    return file.isTxt && file.path != null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
