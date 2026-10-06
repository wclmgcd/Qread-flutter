import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// 阅读页「全屏沉浸」的 iOS 侧实现：隐藏屏幕底部那条 home indicator（小横条）。
///
/// 【为什么需要一个子类】
/// iOS 上「隐藏 home indicator」是 **UIViewController 的能力**
/// （`prefersHomeIndicatorAutoHidden`），不是 App 级的；而且值改了之后必须调
/// `setNeedsUpdateOfHomeIndicatorAutoHidden()` 才会立刻生效。Flutter 没有暴露
/// 这个 API，只能在原生侧开一个 MethodChannel。
///
/// 通道名与方法名跟 Android 侧**完全一致**（`qread/system_ui` /
/// `hideNavigationBar` / `showSystemBars`），所以 Dart 那边一份
/// `SystemUiService` 两端通用 —— 阅读页 `initState` 隐藏、`dispose` 恢复。
///
/// 语义和 Android 的 `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE` 一致：
/// 平时自动淡出，手指碰到屏幕底部时临时出现，松手后再次自动隐藏。
/// 状态栏**不动**（和 Android 侧、以及官方 3.41 一致）。
///
/// 【为什么写在 AppDelegate.swift 里，而不是单独一个文件】
/// 本工程的 Xcode 项目还是老的 `objectVersion = 50` 格式（没有
/// FileSystemSynchronized 分组），新增一个 `.swift` 文件必须手工往
/// `project.pbxproj` 里补 PBXFileReference / PBXBuildFile / group children /
/// Sources build phase 四处，写错一处就是 CI 打包失败。这个类只有几十行，
/// 放进这个**已经在编译列表里**的文件可以完全避开那次改动。
/// 以后要独立成文件，记得同步改 pbxproj。
///
/// 【改名的注意点】
/// 它由 `Base.lproj/Main.storyboard` 通过
/// `customClass="QreadFlutterViewController" customModule="Runner"` 实例化，
/// 两处名字必须一致（模块名来自 `PRODUCT_NAME = $(TARGET_NAME)` = Runner）。
class QreadFlutterViewController: FlutterViewController {

  /// 当前是否隐藏 home indicator。默认 false —— 只有阅读页会把它打开。
  private var homeIndicatorHidden = false

  override var prefersHomeIndicatorAutoHidden: Bool {
    return homeIndicatorHidden
  }

  /// 由本控制器自己决定，不要再去问子控制器
  override var childViewControllerForHomeIndicatorAutoHidden: UIViewController? {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let channel = FlutterMethodChannel(
      name: "qread/system_ui",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(
          FlutterError(
            code: "unavailable",
            message: "QreadFlutterViewController 已释放",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "hideNavigationBar":
        self.setHomeIndicatorHidden(true)
        result(true)
      case "showSystemBars":
        self.setHomeIndicatorHidden(false)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setHomeIndicatorHidden(_ hidden: Bool) {
    if homeIndicatorHidden == hidden { return }
    homeIndicatorHidden = hidden
    // 改完要主动通知系统，否则得等下一次转场才生效
    DispatchQueue.main.async { [weak self] in
      self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
  }
}
