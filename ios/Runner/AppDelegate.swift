import Flutter
import UIKit
import DuanjuCore
import CFNetwork
import AVFoundation
import AVKit
import CoreMedia
import MediaPlayer
import LocalAuthentication

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var originalBrightness: CGFloat?
  private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
  private var mediaControls: MediaControls?
  private var nativePip: NativePictureInPicture?
  private var volumeWatcher: VolumeKeyWatcher?

  private var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private var screen: UIScreen? { keyWindow?.screen }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MediaControls") {
      mediaControls = MediaControls(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativePip") {
      nativePip = NativePictureInPicture(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VolumeWatcher") {
      volumeWatcher = VolumeKeyWatcher(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      let channel = FlutterMethodChannel(name: "duanju/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "battery" {
          let device = UIDevice.current
          device.isBatteryMonitoringEnabled = true
          guard device.batteryLevel >= 0 else {
            result(nil)
            return
          }
          result(["level": Int((device.batteryLevel * 100).rounded()),
                  "charging": device.batteryState == .charging || device.batteryState == .full])
          return
        }
        let arguments = call.arguments as? [String: Any]
        switch call.method {
        case "getBrightness":
          result(self.screen.map { Double($0.brightness) })
          return
        case "setBrightness":
          guard let screen = self.screen, let value = arguments?["brightness"] as? Double else {
            result(nil)
            return
          }
          if self.originalBrightness == nil { self.originalBrightness = screen.brightness }
          screen.brightness = CGFloat(min(max(value, 0.01), 1))
          result(true)
          return
        case "resetBrightness":
          if let original = self.originalBrightness { self.screen?.brightness = original }
          self.originalBrightness = nil
          result(true)
          return
        case "volume":
          result(Double(AVAudioSession.sharedInstance().outputVolume))
          return
        case "setVolume":
          if let value = arguments?["volume"] as? Double {
            if self.volumeView.superview == nil { self.keyWindow?.addSubview(self.volumeView) }
            let slider = self.volumeView.subviews.first { $0 is UISlider } as? UISlider
            slider?.value = Float(min(max(value, 0), 1))
          }
          result(nil)
          return
        case "biometricSupported":
          var biometricError: NSError?
          let biometricContext = LAContext()
          result(biometricContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &biometricError))
          return
        case "biometricAuthenticate":
          let reason = (arguments?["reason"] as? String) ?? "验证身份"
          var biometricError: NSError?
          let biometricContext = LAContext()
          guard biometricContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &biometricError) else {
            // 无生物识别且无设备密码（模拟器等）：直接放行，避免卡死用户。
            result(true)
            return
          }
          biometricContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { result(success) }
          }
          return
        default:
          break
        }
        guard call.method == "systemProxy" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func address(_ prefix: String) -> String {
          guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                let host = settings["\(prefix)Proxy"] as? String,
                let port = settings["\(prefix)Port"] as? NSNumber,
                !host.isEmpty, port.intValue > 0 else { return "" }
          let name = host.contains(":") ? "[\(host)]" : host
          return "http://\(name):\(port.intValue)"
        }
        let http = address("HTTP")
        let https = address("HTTPS")
        result(["http": http, "https": https.isEmpty ? http : https,
                "bypass": settings["ExceptionsList"] as? [String] ?? [],
                "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
      }
    }
  }
}

final class MediaControls {
  private let channel: FlutterMethodChannel
  private var targets: [(MPRemoteCommand, Any)] = []
  private var observers: [NSObjectProtocol] = []
  private var artworkPath = ""
  private var artwork: MPMediaItemArtwork?
  private var playing = false
  private var resumeAfterInterruption = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "update":
        self?.update(call.arguments as? [String: Any] ?? [:])
      case "clear":
        self?.clear()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, !self.targets.isEmpty,
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if type == .began {
        self.resumeAfterInterruption = self.playing
        if self.playing { self.send("pause") }
        return
      }
      let options = AVAudioSession.InterruptionOptions(
        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      if self.resumeAfterInterruption && options.contains(.shouldResume) { self.send("play") }
      self.resumeAfterInterruption = false
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, self.playing,
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      self.send("pause")
    })
  }

  private func send(_ command: String, positionMs: Double? = nil) {
    var arguments: [String: Any] = ["command": command]
    if let positionMs { arguments["positionMs"] = positionMs }
    channel.invokeMethod("command", arguments: arguments)
  }

  private func bind(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> Void) {
    let token = command.addTarget { event in
      handler(event)
      return .success
    }
    targets.append((command, token))
  }

  private func update(_ args: [String: Any]) {
    let commands = MPRemoteCommandCenter.shared()
    if targets.isEmpty {
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .moviePlayback)
      try? session.setActive(true)
      bind(commands.playCommand) { [weak self] _ in self?.send("play") }
      bind(commands.pauseCommand) { [weak self] _ in self?.send("pause") }
      bind(commands.togglePlayPauseCommand) { [weak self] _ in self?.send("toggle") }
      bind(commands.nextTrackCommand) { [weak self] _ in self?.send("next") }
      bind(commands.previousTrackCommand) { [weak self] _ in self?.send("previous") }
      bind(commands.changePlaybackPositionCommand) { [weak self] event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
        self?.send("seek", positionMs: event.positionTime * 1000)
      }
    }
    playing = args["playing"] as? Bool ?? false
    commands.previousTrackCommand.isEnabled = args["hasPrevious"] as? Bool ?? false
    commands.nextTrackCommand.isEnabled = args["hasNext"] as? Bool ?? false
    let path = args["artwork"] as? String ?? ""
    if path != artworkPath {
      artworkPath = path
      artwork = path.isEmpty ? nil : UIImage(contentsOfFile: path).map { image in
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
    }
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
    let duration = ((args["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["subtitle"] as? String ?? "",
      MPNowPlayingInfoPropertyElapsedPlaybackTime: ((args["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
  }

  private func clear() {
    for (command, token) in targets { command.removeTarget(token) }
    targets.removeAll()
    playing = false
    resumeAfterInterruption = false
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
  }
}

// MARK: - 系统画中画（AVPlayer + AVPictureInPictureController）
// media_kit 使用 libmpv 渲染，无法直接系统 PiP；进入 PiP 时用独立 AVPlayer
// 播放同一地址（Go 核心提供的本地代理，已含鉴权/解密），与 Flutter 播放器同步进度。
@available(iOS 15.0, *)
final class NativePictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var pipController: AVPictureInPictureController?
  private var playerItem: AVPlayerItem?
  private var timeObserver: Any?
  private var lastRate = 1.0
  private var kvoToken: NSKeyValueObservation?
  private var pendingSeek: CMTime?
  private var startAttempt = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/pip", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "supported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "enter":
        self.enter(call.arguments as? [String: Any] ?? [:])
        result(true)
      case "exit":
        self.exit()
        result(nil)
      case "update":
        self.update(call.arguments as? [String: Any] ?? [:])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func prepareAudio() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
  }

  private func enter(_ args: [String: Any]) {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          let urlString = args["url"] as? String,
          let url = URL(string: urlString) else {
      channel.invokeMethod("state", arguments: ["active": false, "error": "当前设备不支持系统画中画"])
      return
    }
    cleanup()
    prepareAudio()

    var options: [String: Any] = [:]
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    let newPlayer = AVPlayer(playerItem: item)
    newPlayer.rate = 0

    let layer = AVPlayerLayer(player: newPlayer)
    layer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
    layer.videoGravity = .resizeAspect

    // AVKit 只允许为「已上屏并完成渲染」的 layer 启动 PiP；用一个极小的
    // 承载视图挂到 keyWindow，确保 layer 真正进入窗口层级。
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    host.backgroundColor = .clear
    host.alpha = 0.02
    host.isUserInteractionEnabled = false
    if let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) {
      window.addSubview(host)
      window.bringSubviewToFront(host)
      host.layer.addSublayer(layer)
      self.pipHost = host
    }

    self.player = newPlayer
    self.playerItem = item
    self.playerLayer = layer

    if #available(iOS 15.0, *),
       let controller = AVPictureInPictureController(playerLayer: layer) {
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      self.pipController = controller
    } else {
      channel.invokeMethod("state", arguments: ["active": false, "error": "无法创建画中画控制器"])
      cleanup()
      return
    }

    let position = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
    self.lastRate = rate > 0 ? rate : 1
    self.pendingSeek = CMTime(value: Int64(position), timescale: 1000)

    // 等 AVPlayerItem 真正就绪后再 seek + 启动，避免在未就绪时触发 -1001。
    if item.status == .readyToPlay {
      seekAndStart(item, newPlayer)
    } else {
      kvoToken = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
        DispatchQueue.main.async {
          guard let self else { return }
          switch observed.status {
          case .readyToPlay:
            self.kvoToken = nil
            self.seekAndStart(item, newPlayer)
          case .failed:
            self.kvoToken = nil
            let message = observed.error?.localizedDescription ?? "视频加载失败，无法进入画中画"
            self.channel.invokeMethod("state", arguments: ["active": false, "error": message])
            self.cleanup()
          default:
            break
          }
        }
      }
    }
  }

  private func seekAndStart(_ item: AVPlayerItem, _ newPlayer: AVPlayer) {
    let time = pendingSeek ?? .zero
    pendingSeek = nil
    item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        newPlayer.rate = Float(self.lastRate)
        self.startPictureInPicture()
      }
    }
  }

  /// 阶梯重试启动 PiP：startPictureInPicture 是异步的，且 AVKit 要求 layer
  /// 先完成一次渲染；在短间隔内反复尝试直到窗口真正弹出，规避 -1001「操作无法完成」。
  private func startPictureInPicture() {
    guard let controller = pipController, !controller.isPictureInPictureActive else { return }
    controller.startPictureInPicture()
    let delays: [Double] = [0.35, 0.6, 0.9, 1.2]
    guard startAttempt < delays.count else { return }
    let delay = delays[startAttempt]
    startAttempt += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      if self.pipController?.isPictureInPictureActive != true {
        self.startPictureInPicture()
      }
    }
  }

  private var pipHost: UIView?

  private func update(_ args: [String: Any]) {
    guard let player else { return }
    if let playing = args["playing"] as? Bool {
      player.rate = playing ? Float(lastRate) : 0
    }
    if let rate = (args["rate"] as? NSNumber)?.doubleValue, rate > 0 {
      lastRate = rate
      if player.rate > 0 { player.rate = Float(rate) }
    }
    if let seeking = args["seek"] as? Bool, seeking,
       let position = (args["positionMs"] as? NSNumber)?.doubleValue {
      player.seek(to: CMTime(value: Int64(position), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
  }

  private func exit() {
    pipController?.stopPictureInPicture()
    cleanup()
  }

  private func cleanup() {
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    timeObserver = nil
    kvoToken = nil
    pendingSeek = nil
    startAttempt = 0
    player?.pause()
    pipController?.delegate = nil
    pipController = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    pipHost?.removeFromSuperview()
    pipHost = nil
    playerItem = nil
    player = nil
  }

  // MARK: AVPictureInPictureControllerDelegate
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    channel.invokeMethod("state", arguments: ["active": true])
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    channel.invokeMethod("state", arguments: ["active": false])
    cleanup()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    channel.invokeMethod("state", arguments: ["active": false, "error": error.localizedDescription])
    cleanup()
  }
}

// MARK: - 实体音量键提示（监听系统输出音量变化）
final class VolumeKeyWatcher: NSObject {
  private let channel: FlutterMethodChannel
  private var observation: NSKeyValueObservation?
  private var suppress = false
  private var lastVolume: Float = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/volume", binaryMessenger: messenger)
    super.init()
    lastVolume = AVAudioSession.sharedInstance().outputVolume
    observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
      guard let self else { return }
      let value = session.outputVolume
      if abs(value - self.lastVolume) < 0.001 { return }
      self.lastVolume = value
      if self.suppress { return }
      self.channel.invokeMethod("changed", arguments: [
        "volume": Double(value),
        "enabled": true,
      ])
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "setEnabled":
        // enabled 状态由 Flutter 侧维护，这里仅应答。
        result(nil)
      case "beginSuppressed", "endSuppressed":
        self.suppress = call.method == "beginSuppressed"
        result(nil)
      case "volume":
        result(Double(AVAudioSession.sharedInstance().outputVolume))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
