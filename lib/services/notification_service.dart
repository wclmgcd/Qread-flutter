import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知封装 —— 目前服务两件事：朗读常驻通知、全本缓存进度通知。
///
/// 【三个设计决定】
/// 1. **只暴露单例**：通知是全局能力，页面各 new 一个 plugin 实例的话，
///    Android 上的通知 id 空间会互相打架。
/// 2. **iOS 上不带按钮**：通知动作在 iOS 要在初始化时先注册
///    `DarwinNotificationCategory`，行为受系统限制多，这里只发普通通知。
/// 3. **前台服务只在 Android 上跑**：iOS 没有这个概念，硬调会崩。
///
/// 【为什么朗读要用前台服务而不是普通通知】
/// Android 上 App 退到后台后，普通通知保不住进程 —— 系统内存一紧就回收，
/// 声音直接断。前台服务是系统级的「我正在干活」声明，配合常驻通知，
/// 才能让用户锁屏听书。
///
/// 【22.x 的 API 是命名参数】
/// flutter_local_notifications 在 19 → 22 之间把 initialize / show / cancel /
/// startForegroundService 的位置参数**全改成了命名参数**；另外
/// `startForegroundService` 收的是 `AndroidNotificationDetails`
/// （不是 `NotificationDetails`）。本项目用 22.3.2，按新签名写。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const int _ttsNotificationId = 101;
  static const int _downloadNotificationId = 102;

  static const String _ttsChannelId = 'qread_tts';
  static const String _downloadChannelId = 'qread_download';

  /// 通知按钮的 action id —— 和写进通知的按钮保持一致。
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
      settings: settings,
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
  /// Android 13 起是运行时权限，iOS 每次都要问；用户拒绝后返回 false。
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
    final androidDetails = _ttsAndroidDetails(playing: playing, text: body);

    if (_isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      try {
        // 前台服务：锁屏/后台也保得住发声进程。
        // foregroundServiceTypes 必须与 app 侧 AndroidManifest 里
        // <service android:foregroundServiceType="mediaPlayback"> 对应，
        // 否则 Android 14 会直接抛异常。
        await android?.startForegroundService(
          id: _ttsNotificationId,
          title: title,
          body: body,
          notificationDetails: androidDetails,
          foregroundServiceTypes: const {
            AndroidServiceForegroundType.foregroundServiceTypeMediaPlayback,
          },
        );
        return;
      } catch (e) {
        // Android 12+ 对「后台启动前台服务」有限制，部分 ROM 会直接拒绝。
        // 不能让它把朗读整个搞挂 —— 退化成普通常驻通知：
        // App 在前台时体验一致，只是退到后台后可能被系统回收。
        debugPrint('前台服务启动失败，退化为普通通知: $e');
      }
    }

    await _plugin.show(
      id: _ttsNotificationId,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(presentAlert: false),
      ),
      payload: 'tts',
    );
  }

  AndroidNotificationDetails _ttsAndroidDetails({
    required bool playing,
    required String text,
  }) {
    return AndroidNotificationDetails(
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
    );
  }

  /// 停止朗读：退出前台服务并取消通知。
  Future<void> cancelTts() async {
    if (_isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // 不先停前台服务的话，通知会被系统立刻重新拉起来
      //（系统看到「前台服务没有通知」就会补一条）。
      try {
        await android?.stopForegroundService();
      } catch (e) {
        debugPrint('停止前台服务失败: $e');
      }
    }
    await _plugin.cancel(id: _ttsNotificationId);
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
    final max = total <= 0 ? 1 : total;
    await _plugin.show(
      id: _downloadNotificationId,
      title: '正在缓存《$bookName》',
      body: '$done / $total 章',
      notificationDetails: NotificationDetails(
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
          maxProgress: max,
          progress: done.clamp(0, max),
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
    await _plugin.cancel(id: _downloadNotificationId);
    await _plugin.show(
      id: _downloadNotificationId,
      title: '《$bookName》缓存完成',
      body: failed == 0 ? '共 $done 章' : '成功 $done 章，失败 $failed 章',
      notificationDetails: const NotificationDetails(
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

  Future<void> cancelDownload() => _plugin.cancel(id: _downloadNotificationId);
}
