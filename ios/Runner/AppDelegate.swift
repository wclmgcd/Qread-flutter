import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // 冷启动：从「用其他应用打开」进来的文件，URL 在 launchOptions 里。
    // 此刻 Flutter 引擎还没建好，FileOpenBridge 会先把它攒起来，
    // 等 Dart 侧就绪后自己来取（见 FileOpenBridge.attach / getInitialFile）。
    if let url = launchOptions?[.url] as? URL {
      FileOpenBridge.shared.handle(url: url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 热启动：App 已在后台时，从「打开方式」/「分享」进来的文件走这里。
  ///
  /// 必须调 `super` —— FlutterAppDelegate 自己也要处理一遍（url_launcher 等
  /// 插件依赖它）。这里只是**顺带**把文件抄一份给 FileOpenBridge。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    FileOpenBridge.shared.handle(url: url)
    return super.application(app, open: url, options: options)
  }
}

/// 「打开方式」桥：把外部传来的 .json 文件交给 Dart。
///
/// 【对应关系】
/// 通道名与方法名跟 Android 侧（MainActivity.kt）**完全一致**，
/// 所以 Dart 那边一份 `FileOpenService` 两端通用：
///
///   Dart → 原生：`getInitialFile`            取「冷启动带进来的那个文件」
///   原生 → Dart：`onFileOpened`              推「热启动进来的文件」
///
/// 【为什么需要 pending 缓冲】
/// iOS 也是「先拿到文件、后建好 Flutter 引擎」：
/// `didFinishLaunchingWithOptions` 比 `QreadFlutterViewController.viewDidLoad`
/// 早。所以文件先存进 `pending`，等通道挂上、Dart 来取。
///
/// 【为什么不引第三方插件】
/// 同 Android 侧：本机没有 Flutter SDK，改 pubspec 无法本地验证依赖解析，
/// 一旦解析失败就是 CI 红。这里逻辑很短，自己开通道更可控。
final class FileOpenBridge {
  static let shared = FileOpenBridge()

  private var channel: FlutterMethodChannel?
  private var pending: [String: String]?

  private init() {}

  /// 由 `QreadFlutterViewController.viewDidLoad` 调用（引擎就绪时）。
  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "qread/file_open",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "getInitialFile":
        // 取走即清空，否则用户下次从后台切回来会重复弹一次导入框
        let file = self.pending
        self.pending = nil
        result(file)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// 收到一个文件：能直接推就推，推不了（Dart 还没挂 handler）就攒着。
  func deliver(_ file: [String: String]) {
    guard let channel = channel else {
      pending = file
      return
    }
    channel.invokeMethod("onFileOpened", arguments: file) { [weak self] result in
      // Dart 侧 handler 还没注册时，引擎会回一个 FlutterError
      // （MethodNotImplemented）。这时退回 pending，等 Dart 来取。
      if result is FlutterError {
        self?.pending = file
      }
    }
  }

  /// 读一个「打开方式」进来的 URL 并把内容交给 Dart。
  func handle(url: URL) {
    guard let file = FileOpenBridge.read(url) else { return }
    deliver(file)
  }

  private static func read(_ url: URL) -> [String: String]? {
    // 文件是通过「打开方式」传进来的，位于本 App 沙盒之外，
    // 必须先申请安全作用域访问权，否则 Data(contentsOf:) 直接抛权限错误。
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    return ["name": url.lastPathComponent, "content": text]
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

    // 「打开方式」桥：通道名/方法名与 Android 侧 MainActivity.kt 完全一致。
    // 放在这里而不是 AppDelegate 里，是因为只有到这一步 Flutter 引擎
    // （binaryMessenger）才真正可用。
    FileOpenBridge.shared.attach(messenger: binaryMessenger)

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
