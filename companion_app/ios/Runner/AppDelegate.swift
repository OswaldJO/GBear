import Flutter
import GameController
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "com.gbear.companion/streaming_bridge"
  private let pluginId = "GBearStreamingBridge"
  private var streamingChannelRegistered = false
  private var streamingChannel: FlutterMethodChannel?
  private weak var videoController: GBearVideoViewController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerStreamingChannelIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.registerStreamingChannelIfNeeded()
    }
    return result
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    registerStreamingChannelIfNeeded()
  }

  private func flutterViewController() -> FlutterViewController? {
    if let root = window?.rootViewController as? FlutterViewController {
      return root
    }
    if #available(iOS 13.0, *) {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows where window.isKeyWindow {
          if let root = window.rootViewController as? FlutterViewController {
            return root
          }
        }
      }
    }
    return nil
  }

  private func flutterMessenger() -> FlutterBinaryMessenger? {
    if let registrar = registrar(forPlugin: pluginId) {
      return registrar.messenger()
    }
    return flutterViewController()?.binaryMessenger
  }

  private func registerStreamingChannelIfNeeded() {
    guard !streamingChannelRegistered else { return }
    guard let messenger = flutterMessenger() else { return }
    streamingChannelRegistered = true

    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    streamingChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleStreamingCall(call, result: result)
    }
  }

  private func handleStreamingCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "discoverHosts":
      result([])

    case "pairWithPin":
      result(true)

    case "getStreamSession":
      let viewerOpen = videoController != nil
      result([
        "hostStreamActive": viewerOpen,
        "viewerOpen": viewerOpen,
      ])

    case "prepareForNewStream":
      if let player = videoController {
        _ = player.stopFromHost(notifyFlutter: false)
        player.removeFromFlutterParentIfNeeded()
        videoController = nil
      }
      result(nil)

    case "resumeStream":
      result(false)

    case "isSimulator":
      #if targetEnvironment(simulator)
      result(true)
      #else
      result(false)
      #endif

    case "startStream":
      guard let flutterVC = flutterViewController() else {
        result(
          FlutterError(
            code: "no_controller",
            message: "Flutter view controller is not ready yet. Try again.",
            details: nil
          )
        )
        return
      }
      guard let args = call.arguments as? [String: Any],
            let host = args["host"] as? String,
            let port = args["videoPort"] as? Int else {
        result(FlutterError(code: "invalid_args", message: "Missing stream configuration", details: nil))
        return
      }
      let width = args["width"] as? Int ?? 1920
      let height = args["height"] as? Int ?? 1080
      let videoHost = Self.videoTCPHost(settingsHost: host)
      if videoHost != host {
        GBearStreamLog.i("Video TCP using \(videoHost) (control plane host was \(host))")
      }
      let player = GBearVideoViewController(host: videoHost, port: UInt16(port), width: width, height: height)
      player.modalPresentationStyle = .fullScreen
      player.onStreamEnded = { [weak self] logPath in
        self?.videoController = nil
        self?.notifyStreamStopped(logPath: logPath)
      }
      videoController = player
      // Reply on the platform thread *before* main-queue work. iPhone 8 can stall the main
      // run loop for seconds; deferring result(true) into main.async left Flutter on
      // "Starting Desktop stream…" while the Mac kept encoding with no TCP viewer.
      result(true)
      DispatchQueue.global(qos: .userInitiated).async {
        GBearStreamLog.startSession(host: videoHost, port: port, width: width, height: height)
      }
      DispatchQueue.main.async {
        Self.attachStreamPlayer(player, to: flutterVC)
      }

    case "stopStream":
      if let player = videoController {
        let logPath = player.stopFromHost(notifyFlutter: false)
        videoController = nil
        result(logPath.map { ["logPath": $0] } ?? [:])
      } else {
        let logPath = GBearStreamLog.endSession(reason: "stop requested (no video open)")
        result(logPath.map { ["logPath": $0] } ?? [:])
      }

    case "clearPendingExternalStopLog":
      result(nil)

    case "listConnectedControllers":
      result(Self.listConnectedControllers())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func notifyStreamStopped(logPath: String?) {
    var args: [String: Any] = [:]
    if let logPath, !logPath.isEmpty {
      args["logPath"] = logPath
    }
    streamingChannel?.invokeMethod("onStreamStoppedExternally", arguments: args)
  }

  /// Modal `present` from Flutter often crashes on the iOS Simulator; embed full-screen instead.
  private static func attachStreamPlayer(
    _ player: GBearVideoViewController,
    to flutterVC: FlutterViewController
  ) {
    #if targetEnvironment(simulator)
    player.removeFromFlutterParentIfNeeded()
    player.view.translatesAutoresizingMaskIntoConstraints = false
    flutterVC.addChild(player)
    flutterVC.view.addSubview(player.view)
    NSLayoutConstraint.activate([
      player.view.topAnchor.constraint(equalTo: flutterVC.view.topAnchor),
      player.view.bottomAnchor.constraint(equalTo: flutterVC.view.bottomAnchor),
      player.view.leadingAnchor.constraint(equalTo: flutterVC.view.leadingAnchor),
      player.view.trailingAnchor.constraint(equalTo: flutterVC.view.trailingAnchor),
    ])
    player.didMove(toParent: flutterVC)
    #else
    let presenter = topViewController(base: flutterVC) ?? flutterVC
    presenter.present(player, animated: false)
    #endif
  }

  private static func topViewController(base: UIViewController?) -> UIViewController? {
    if let nav = base as? UINavigationController {
      return topViewController(base: nav.visibleViewController)
    }
    if let tab = base as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = base?.presentedViewController {
      return topViewController(base: presented)
    }
    return base
  }

  /// iOS Simulator shares the Mac network stack; LAN IPs (e.g. 192.168.x.x) often never reach TCP video.
  private static func videoTCPHost(settingsHost: String) -> String {
    #if targetEnvironment(simulator)
    return "127.0.0.1"
    #else
    return settingsHost
    #endif
  }

  private static var controllerDiscoveryStarted = false

  private static func listConnectedControllers() -> [[String: Any]] {
    if !controllerDiscoveryStarted {
      controllerDiscoveryStarted = true
      GCController.startWirelessControllerDiscovery(completionHandler: {})
    }
    return GCController.controllers().map { controller in
      let name = controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayName = (name?.isEmpty == false) ? name! : "Game Controller"
      var entry: [String: Any] = [
        "id": controller.playerIndex.rawValue.description,
        "name": displayName,
      ]
      if #available(iOS 13.0, *) {
        entry["vendor"] = controller.productCategory
      } else {
        entry["vendor"] = "gamepad"
      }
      return entry
    }
  }
}
