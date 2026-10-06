package com.qread.qread

import android.os.Build
import android.view.View
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 阅读页的「全屏沉浸」：隐藏系统导航栏（底部手势条 / 三大金刚键）。
 *
 * 【为什么必须在原生侧做】
 * Flutter 的 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`
 * 底层是 `View.setSystemUiVisibility(SYSTEM_UI_FLAG_* | IMMERSIVE_STICKY)`。
 * 而从 Android 15（API 35）起系统强制 edge-to-edge，并**忽略**这些 flag ——
 * Flutter 引擎源码里也明确写着：
 *   "If the Flutter Android app targets Android SDK 15 (API 35) or later then
 *    the Android system will ignore this value unless the app also follows the
 *    opt out instructions."
 * 而那条 opt-out（`windowOptOutEdgeToEdgeEnforcement`）在 Android 16 上会崩。
 * 所以纯 Flutter 写法在现在的手机上是**完全无效**的 —— 这正是用户反馈
 * 「屏幕底部的小横条还是自动无法隐藏」的原因。
 *
 * 正确姿势是 `WindowInsetsControllerCompat.hide(navigationBars())` 配合
 * `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`：从 API 30 一直有效到 Android 16，
 * 且「滑一下临时出现、松手又自己收回去」，就是用户要的「自动隐藏」。
 * 状态栏保持不动（3.41 阅读时状态栏也是显示的）。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "qread/system_ui"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hideNavigationBar" -> {
                        hideNavigationBar()
                        result.success(true)
                    }
                    "showSystemBars" -> {
                        showSystemBars()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hideNavigationBar() {
        val window = window ?: return
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        // 划一下临时出现，松手后自己收回去
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            controller.hide(WindowInsetsCompat.Type.navigationBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                window.decorView.systemUiVisibility or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    private fun showSystemBars() {
        val window = window ?: return
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            controller.show(WindowInsetsCompat.Type.systemBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }
}
