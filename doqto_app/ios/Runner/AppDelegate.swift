import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // H4: covers the window while the app is inactive so the task-switcher
  // snapshot never shows PHI.
  private var privacyOverlay: UIVisualEffectView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerFileProtectionChannel()
    // Required by flutter_local_notifications so foreground banners and
    // notification taps are routed to the plugin.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }
    // Under the UIScene lifecycle the applicationWillResignActive /
    // applicationDidBecomeActive delegate callbacks never fire — UIApplication
    // still posts the equivalent notifications, so H4 hangs off those instead.
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(coverForPrivacy),
      name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(uncoverForPrivacy),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Chat media cache (lib/data/services/chat_media_cache.dart): mark a path
  /// NSFileProtectionComplete so cached PHI is unreadable while the phone is
  /// locked. Files created inside a protected directory inherit the class.
  /// Uses a plugin registrar because there is no root FlutterViewController
  /// under the scene lifecycle.
  private func registerFileProtectionChannel() {
    guard let registrar = self.registrar(forPlugin: "DoqtoFileProtection") else { return }
    let channel = FlutterMethodChannel(
      name: "doqto/file_protection", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "complete",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
        result(nil)
      } catch {
        result(FlutterError(code: "protect_failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  /// self.window is nil under the scene lifecycle; the scene owns the window.
  private var activeWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow } ?? self.window
  }

  @objc private func coverForPrivacy() {
    guard privacyOverlay == nil, let window = activeWindow else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyOverlay = blur
  }

  @objc private func uncoverForPrivacy() {
    privacyOverlay?.removeFromSuperview()
    privacyOverlay = nil
  }
}
