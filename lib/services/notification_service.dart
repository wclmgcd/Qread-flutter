import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知封装 —— 目前服务两件事：朗读常驻通知、全本缓存进度通知。
///
/// 【三个设计决定】
/// 1. **只暴露静态方法式的单例**：通知是全局能力，页面不该各自 new 一个
///    plugin 实例（实例多了 Android 上的通知 id 空间会互相打架）。
/// 2. **iOS 上不带按钮**：通知动作在 iOS 要在初始化时先注册
///    `DarwinNotificationCategory`，且按钮数量/行为受系统限制，
///    这里只发一条普通通知，够用且不用赌 API。
/// 3. **前台服务只在 Android 上跑**：iOS 没有这个概念，硬调会崩。
///
/// 【为什么朗读要用前台服务而不是普通通知】
/// Android 上 App 退到后台后，普通通知保不住进程 —— 系统内存一紧就回收，
/// 声音直接断。前台服务是系统级的「我正在干活」声明，配合常驻通知，
/// 才能让用户锁屏听书。代价是通知栏会有个持续存在的条目，这正是用户想要的。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const int _ttsNotificationId = 101;
  static const int _downloadNotificationId = 102;

  static const String _ttsChannelId = 'qread_tts';
  static const String _downloadChannelId = 'qread_download';

  /// 通知按钮的 action id —— 和 Android/iOS 通知里写的保持一致。
  static const String actionPrev = 'tts_prev';
  static const String actionToggle = 'tts_toggle';
  static const String actionStop = 'tts_stop';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 通知按钮回调：参数是上面的 action id。
  ///
  /// 由阅读页在 initState 里挂上、dispose 里摘掉 —— 没人在阅读页时
  /// 通知按钮就算按了也没有可执行的对象。
  ValueChanged<String>? onTtsAction;

  bool _initialized = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    if (_isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // 渠道是 Android 8 起的硬性要求：不建渠道，通知直接不显示。
      // 朗读渠道设成 low 重要性 —— 它是「状态条」不是「提醒」，不该响铃弹窗。
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _ttsChannelId,
          '朗读',
          description: '听书进行中，可在此暂停或停止',
          importance: Importance.low,
        ),
      );
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _downloadChannelId,
          '缓存下载',
          description: '全本缓存的进度与完成提示',
          importance: Importance.low,
        ),
      );
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    final id = response.actionId;
    if (id == null) return;
    if (id == actionPrev || id == actionToggle || id == actionStop) {
      onTtsAction?.call(id);
    }
  }

  /// 申请通知权限。
  ///
  /// Android 13 起是运行时权限，iOS 每次都要问；用户拒绝后返回 false，
  /// 调用方应该给一句「去设置里打开通知」的提示，而不是静默失败。
  Future<bool> requestPermission() async {
    if (_isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true; // 13 以下没有这个 API，视为已授权
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final granted = await ios?.requestPermissions(
      alert: true,
      badge: false,
      sound: false,
    );
    return granted ?? true;
  }

  // ============================================================
  // 朗读通知
  // ============================================================

  /// 更新/显示朗读常驻通知。
  ///
  /// [playing] 决定中间那个按钮显示「暂停」还是「继续」——
  /// 通知一旦发出就不能改按钮文案，只能整体重发（用同一个 id 覆盖）。
  Future<void> showTts({
    required String bookName,
    required String chapterTitle,
    required bool playing,
  }) async {
    final title = bookName.isEmpty ? '正在朗读' : bookName;
    final body = chapterTitle.isEmpty ? '听书进行中' : chapterTitle;

    if (_isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // 前台服务模式下要用 startForegroundService 发第一条，
      // 之后更新用普通 show 即可（同一个 id 会覆盖）。
      await android?.startForegroundService(
        _ttsNotificationId,
        title,
        body,
        notificationDetails: _ttsDetails(playing: playing, text: body),
      );
      return;
    }

    await _plugin.show(
      _ttsNotificationId,
      title,
      body,
      _ttsDetails(playing: playing, text: body),
      payload: 'tts',
    );
  }

  NotificationDetails _ttsDetails({
    required bool playing,
    required String text,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _ttsChannelId,
        '朗读',
        channelDescription: '听书进行中，可在此暂停或停止',
        importance: Importance.low,
        priority: Priority.low,
        // 常驻：不随用户滑动清除，只在停止朗读时由代码取消
        ongoing: true,
        autoCancel: false,
        // 更新内容时不要再响一次铃/震一次
        onlyAlertOnce: true,
        showWhen: false,
        styleInformation: BigTextStyleInformation(text),
        actions: [
          const AndroidNotificationAction(actionPrev, '上一段'),
          AndroidNotificationAction(
            actionToggle,
            playing ? '暂停' : '继续',
            // 点按钮只执行动作，不要把通知本身收掉
            cancelNotification: false,
          ),
          const AndroidNotificationAction(actionStop, '停止'),
        ],
      ),
      iOS: const DarwinNotificationDetails(presentAlert: false),
    );
  }

  /// 停止朗读：取消通知并退出前台服务。
  Future<void> cancelTts() async {
    if (_isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // 不先停前台服务的话，通知会被系统立刻重新拉起来
      // （系统看到「前台服务没有通知」就会补一条）。
      await android?.stopForegroundService();
    }
    await _plugin.cancel(_ttsNotificationId);
  }

  // ============================================================
  // 缓存下载通知
  // ============================================================

  /// 全本缓存进行中：显示进度条。
  Future<void> showDownloadProgress({
    required String bookName,
    required int done,
    required int total,
  }) async {
    await _plugin.show(
      _downloadNotificationId,
      '正在缓存《$bookName》',
      '$done / $total 章',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _downloadChannelId,
          '缓存下载',
          channelDescription: '全本缓存的进度与完成提示',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: total <= 0 ? 1 : total,
          progress: done.clamp(0, total <= 0 ? 1 : total),
        ),
        iOS: const DarwinNotificationDetails(presentAlert: false),
      ),
      payload: 'download',
    );
  }

  /// 全本缓存结束：收掉进度条，给一条结果通知。
  Future<void> showDownloadDone({
    required String bookName,
    required int done,
    required int failed,
  }) async {
    await _plugin.cancel(_downloadNotificationId);
    await _plugin.show(
      _downloadNotificationId,
      '《$bookName》缓存完成',
      failed == 0 ? '共 $done 章' : '成功 $done 章，失败 $failed 章',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _downloadChannelId,
          '缓存下载',
          channelDescription: '全本缓存的进度与完成提示',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true),
      ),
      payload: 'download_done',
    );
  }

  Future<void> cancelDownload() => _plugin.cancel(_downloadNotificationId);
}
