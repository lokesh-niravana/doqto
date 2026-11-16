import AVFoundation
import Flutter
import Network
import Photos
import QuickLook
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import VisionKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // H4: covers the window while the app is inactive so the task-switcher
  // snapshot never shows PHI.
  private var privacyOverlay: UIVisualEffectView?
  // QLPreviewController holds its data source weakly.
  private var documentPreview: DocumentPreview?
  // VNDocumentCameraViewController holds its delegate weakly.
  private var documentScan: DocumentScan?
  private var mediaChannel: FlutterMethodChannel?
  private var proximityObserver: NSObjectProtocol?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerFileProtectionChannel()
    registerDocumentChannel()
    registerBadgeChannel()
    registerClipboardChannel()
    registerMediaChannel()
    registerDeviceChannel()
    registerScreenshotChannel()
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

  /// Batch 5 media (lib/data/services/media_native.dart). System frameworks
  /// only — AVFoundation, Photos, VisionKit, Network — so no plugin binary
  /// framework (ITMS-90111) comes with video posters, Save to Photos, the
  /// document scanner, the radio type or the earpiece route.
  private func registerMediaChannel() {
    guard let registrar = self.registrar(forPlugin: "DoqtoMedia") else { return }
    let channel = FlutterMethodChannel(
      name: "doqto/media", binaryMessenger: registrar.messenger())
    mediaChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "videoPoster":
        guard let path = args["path"] as? String else { result(FlutterMethodNotImplemented); return }
        let maxSide = args["maxSide"] as? Int ?? 720
        DispatchQueue.global(qos: .userInitiated).async {
          let poster = self.videoPoster(path: path, maxSide: maxSide)
          DispatchQueue.main.async { result(poster) }
        }
      case "saveToPhotos":
        guard let path = args["path"] as? String else { result(FlutterMethodNotImplemented); return }
        self.saveToPhotos(path: path, result: result)
      case "scanDocument":
        guard let out = args["path"] as? String else { result(FlutterMethodNotImplemented); return }
        self.scanDocument(outputPath: out, result: result)
      case "networkType":
        self.networkType(result: result)
      case "setEarpiece":
        self.setEarpiece(args["earpiece"] as? Bool ?? false)
        result(nil)
      case "proximityStart":
        self.proximity(enabled: true)
        result(nil)
      case "proximityStop":
        self.proximity(enabled: false)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// First frame of a clip as JPEG, longest side ≤ maxSide, plus the
  /// dimensions of that frame and the clip length. Nil when AVFoundation
  /// cannot read the file.
  private func videoPoster(path: String, maxSide: Int) -> [String: Any]? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxSide, height: maxSide)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    let durationSec = CMTimeGetSeconds(asset.duration)
    // A hair past zero: the very first frame of many camera clips is black.
    let at = CMTime(seconds: min(0.1, max(0, durationSec / 2)), preferredTimescale: 600)
    guard let cg = try? generator.copyCGImage(at: at, actualTime: nil) else { return nil }
    let image = UIImage(cgImage: cg)
    guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
    return [
      "jpeg": FlutterStandardTypedData(bytes: jpeg),
      "width": Int(image.size.width),
      "height": Int(image.size.height),
      "durationMs": Int((durationSec.isFinite ? durationSec : 0) * 1000),
    ]
  }

  /// PHPhotoLibrary add-only: the app never reads the library here.
  private func saveToPhotos(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let isVideo: Bool = {
      if let type = UTType(filenameExtension: url.pathExtension) { return type.conforms(to: .movie) }
      return false
    }()
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { result(false) }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        if isVideo {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } else {
          PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
      }) { ok, _ in
        DispatchQueue.main.async { result(ok) }
      }
    }
  }

  /// VisionKit document camera → one PDF page per scanned sheet, written
  /// with UIGraphicsPDFRenderer. nil = no scanner on this device, false =
  /// the user backed out, true = PDF at outputPath.
  private func scanDocument(outputPath: String, result: @escaping FlutterResult) {
    guard VNDocumentCameraViewController.isSupported, let top = topViewController() else {
      result(nil)
      return
    }
    let scan = DocumentScan(outputPath: outputPath) { [weak self] outcome in
      self?.documentScan = nil
      result(outcome)
    }
    documentScan = scan
    let controller = VNDocumentCameraViewController()
    controller.delegate = scan
    top.present(controller, animated: true)
  }

  /// One-shot NWPathMonitor read: "wifi" | "cellular" | "none".
  private func networkType(result: @escaping FlutterResult) {
    let monitor = NWPathMonitor()
    var answered = false
    monitor.pathUpdateHandler = { path in
      guard !answered else { return }
      answered = true
      let type: String
      if path.status != .satisfied {
        type = "none"
      } else if path.usesInterfaceType(.cellular) {
        type = "cellular"
      } else {
        type = "wifi"  // wifi, wired, loopback: all unmetered for our purposes
      }
      monitor.cancel()
      DispatchQueue.main.async { result(type) }
    }
    monitor.start(queue: DispatchQueue.global(qos: .utility))
  }

  /// Voice notes at the ear: play-and-record without defaultToSpeaker sends
  /// output to the receiver; back to .playback restores the loudspeaker.
  private func setEarpiece(_ earpiece: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
      if earpiece {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try session.overrideOutputAudioPort(.none)
      } else {
        try session.setCategory(.playback, mode: .default, options: [])
      }
      try session.setActive(true)
    } catch {
      // Route changes are best effort; playback keeps going either way.
    }
  }

  private func proximity(enabled: Bool) {
    let device = UIDevice.current
    device.isProximityMonitoringEnabled = enabled
    if enabled, proximityObserver == nil {
      proximityObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.mediaChannel?.invokeMethod("proximity", arguments: UIDevice.current.proximityState)
      }
    } else if !enabled, let observer = proximityObserver {
      NotificationCenter.default.removeObserver(observer)
      proximityObserver = nil
    }
  }

  /// Device description for linked devices (lib/data/services/device_info.dart):
  /// the model family plus OS version — "iPhone (iOS 18.1)". UIDevice.name
  /// (the user's own label) needs an entitlement since iOS 16, and a model is
  /// enough to recognise a device in the list. Not PHI.
  private func registerDeviceChannel() {
    guard let registrar = self.registrar(forPlugin: "DoqtoDevice") else { return }
    let channel = FlutterMethodChannel(
      name: "doqto/device", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "name" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let device = UIDevice.current
      result("\(device.model) (\(device.systemName) \(device.systemVersion))")
    }
  }

  /// Screenshot detection (batch 6): iOS cannot block a screenshot, but it
  /// tells us one was taken. Flutter audits it against the open chat
  /// (`POST /audit/screenshot`) and shows a toast.
  private var screenshotChannel: FlutterMethodChannel?

  private func registerScreenshotChannel() {
    guard let registrar = self.registrar(forPlugin: "DoqtoScreenshot") else { return }
    let channel = FlutterMethodChannel(
      name: "doqto/screenshot", binaryMessenger: registrar.messenger())
    screenshotChannel = channel
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenshotTaken),
      name: UIApplication.userDidTakeScreenshotNotification, object: nil)
  }

  @objc private func screenshotTaken() {
    screenshotChannel?.invokeMethod("taken", arguments: nil)
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

/// Collects the VisionKit scan and writes it as a PDF (one page per sheet,
/// page size = image points). Reports true / false / nil through `done`.
private final class DocumentScan: NSObject, VNDocumentCameraViewControllerDelegate {
  private let outputPath: String
  private let done: (Any?) -> Void
  private var finished = false

  init(outputPath: String, done: @escaping (Any?) -> Void) {
    self.outputPath = outputPath
    self.done = done
  }

  private func finish(_ controller: UIViewController, _ outcome: Any?) {
    guard !finished else { return }
    finished = true
    controller.dismiss(animated: true) { self.done(outcome) }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
  ) {
    guard scan.pageCount > 0 else {
      finish(controller, false)
      return
    }
    let url = URL(fileURLWithPath: outputPath)
    do {
      let first = scan.imageOfPage(at: 0)
      let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
      try renderer.writePDF(to: url) { ctx in
        for i in 0..<scan.pageCount {
          let image = scan.imageOfPage(at: i)
          ctx.beginPage(withBounds: CGRect(origin: .zero, size: image.size), pageInfo: [:])
          image.draw(in: CGRect(origin: .zero, size: image.size))
        }
      }
      finish(controller, true)
    } catch {
      finish(controller, false)
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    finish(controller, false)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFailWithError error: Error
  ) {
    finish(controller, false)
  }
}
