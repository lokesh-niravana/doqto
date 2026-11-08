import Flutter
import QuickLook
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  // H4: covers the window while the app is inactive so the task-switcher
  // snapshot never shows PHI.
  private var privacyOverlay: UIVisualEffectView?
  // QLPreviewController holds its data source weakly.
  private var documentPreview: DocumentPreview?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerFileProtectionChannel()
    registerDocumentChannel()
    registerBadgeChannel()
    registerClipboardChannel()
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

  /// Chat documents open in Apple's QuickLook inside the app: PDF, Word,
  /// Excel, PowerPoint and more, rendered on the device.
  private func registerDocumentChannel() {
    guard let registrar = self.registrar(forPlugin: "DoqtoDocuments") else { return }
    let channel = FlutterMethodChannel(
      name: "doqto/documents", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "preview",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let url = URL(fileURLWithPath: path)
      guard QLPreviewController.canPreview(url as NSURL),
        let self = self, let top = self.topViewController()
      else {
        result(false)
        return
      }
      let preview = DocumentPreview(url: url)
      self.documentPreview = preview
      let controller = QLPreviewController()
      controller.dataSource = preview
      controller.modalPresentationStyle = .fullScreen
      top.present(controller, animated: true)
      result(true)
    }
  }

  /// App-icon badge (lib/data/services/app_badge.dart): the unread total
  /// computed from the conversation list. iOS 16+ goes through
  /// UNUserNotificationCenter (the only path that is not deprecated); older
  /// systems set applicationIconBadgeNumber directly.
  private func registerBadgeChannel() {
    guard let registrar = self.registrar(forPlugin: "DoqtoBadge") else { return }
    let channel = FlutterMethodChannel(
      name: "doqto/badge", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "set",
        let args = call.arguments as? [String: Any],
        let count = args["count"] as? Int
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
          if let error = error {
            result(FlutterError(code: "badge_failed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      } else {
        UIApplication.shared.applicationIconBadgeNumber = count
        result(nil)
      }
    }
  }

  /// Copy a message (lib/data/services/app_clipboard.dart): the text lands on
  /// the pasteboard with `.localOnly`, so Universal Clipboard never carries
  /// PHI across to the doctor's other Apple devices.
  private func registerClipboardChannel() {
    guard let registrar = self.registrar(forPlugin: "DoqtoClipboard") else { return }
    let channel = FlutterMethodChannel(
      name: "doqto/clipboard", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "setLocalOnly",
        let args = call.arguments as? [String: Any],
        let text = args["text"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIPasteboard.general.setItems(
        [[UTType.plainText.identifier: text]],
        options: [.localOnly: true])
      result(nil)
    }
  }

  private func topViewController() -> UIViewController? {
    var top = activeWindow?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
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

/// A single file for QuickLook. The title comes from the file name, which is
/// why ChatDocumentStore keeps the real one.
private final class DocumentPreview: NSObject, QLPreviewControllerDataSource {
  private let url: URL

  init(url: URL) {
    self.url = url
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

  func previewController(
    _ controller: QLPreviewController, previewItemAt index: Int
  ) -> QLPreviewItem {
    url as NSURL
  }
}
