import 'dart:async';

import 'package:flutter/material.dart';

import '../config/routes.dart';
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
        .push(
          MaterialPageRoute<bool>(
            builder: (_) => FileImportPage(file: file),
            fullscreenDialog: true,
          ),
        )
        .whenComplete(() => _showing = false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
