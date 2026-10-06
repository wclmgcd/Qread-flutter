import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 阅读页的「全屏沉浸」：隐藏屏幕底部的系统导航栏。
///
/// 【为什么不用 SystemChrome.setEnabledSystemUIMode】
/// Flutter 的 `SystemUiMode.immersiveSticky` / `manual` 底层都是 Android 的
/// `View.setSystemUiVisibility(SYSTEM_UI_FLAG_* | IMMERSIVE_STICKY)`。
/// 从 Android 15（API 35）起系统强制 edge-to-edge 并**忽略**这些 flag，
/// Flutter 引擎源码里也写着「targets Android SDK 15 (API 35) or later then the
/// Android system will ignore this value」。所以那种写法在现在的手机上完全没
/// 效果 —— 这就是用户反馈的「屏幕底部的小横条还是自动无法隐藏」。
/// （唯一的绕法 `windowOptOutEdgeToEdgeEnforcement` 在 Android 16 上会崩。）
///
/// 正确做法是 `WindowInsetsController.hide(navigationBars())` +
/// `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`（滑一下临时出现、松手又自己收），
/// API 30 一直到 Android 16 都有效。Flutter 没暴露这个 API，所以在原生侧开了
/// 一个 MethodChannel，见 `android/app/src/main/kotlin/.../MainActivity.kt`。
///
/// 状态栏**不动** —— 官方 3.41 阅读时状态栏也是显示的，而且阅读页底部
/// 自己画了时间/电量，没必要连状态栏一起藏。
class SystemUiService {
  SystemUiService._();

  static const MethodChannel _channel = MethodChannel('qread/system_ui');

  /// 进入阅读页时调用：隐藏底部系统导航栏（手势条 / 三大金刚键）
  static Future<void> hideNavigationBar() async {
    try {
      await _channel.invokeMethod<void>('hideNavigationBar');
    } on MissingPluginException {
      // iOS / 桌面没有这个通道，静默跳过
    } catch (e) {
      debugPrint('隐藏系统导航栏失败: $e');
    }
  }

  /// 离开阅读页时**必须**调用，否则整个 App 都没有底部导航栏
  static Future<void> showSystemBars() async {
    try {
      await _channel.invokeMethod<void>('showSystemBars');
    } on MissingPluginException {
      // 同上
    } catch (e) {
      debugPrint('恢复系统导航栏失败: $e');
    }
  }
}
