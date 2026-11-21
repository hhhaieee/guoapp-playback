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
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // 隐藏系统音量 HUD：把 MPVolumeView 挂到窗口（屏幕外），这样实体音量键
    // 不再弹系统音量提示，改由 Flutter 侧的自定义小图标接管。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.installSystemVolumeHudSuppressor()
    }
    return launched
  }

  private func installSystemVolumeHudSuppressor() {
    guard volumeView.superview == nil else { return }
    if let window = keyWindow {
      window.addSubview(volumeView)
    }
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
  private var displayToken: NSKeyValueObservation?
  private var lastPipError: String?
  private var autoArmed = false
  private var autoArgs: [String: Any] = [:]
  private var autoObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/pip", binaryMessenger: messenger)
    super.init()
    // 「离开应用时自动画中画」：在 App 即将失去活跃（进入后台/锁屏）的瞬间
    // 启动系统画中画。此时场景仍处于可启动 PiP 的过渡态，成功率最高。
    autoObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.autoArmed,
            !(self.pipController?.isPictureInPictureActive ?? false) else { return }
      self.enter(self.autoArgs)
    }
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
      case "armAuto":
        self.armAuto(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "disarmAuto":
        self.disarmAuto()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func armAuto(_ args: [String: Any]) {
    autoArgs = args
    autoArmed = !args.isEmpty
  }

  private func disarmAuto() {
    autoArmed = false
    autoArgs = [:]
  }

  private func prepareAudio() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
  }

  /// 优先取前台激活场景的窗口，避免多场景/后台时找不到 keyWindow 导致
  /// AVPlayerLayer 未真正挂到窗口层级，从而触发 -1001。
  private var foregroundWindow: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
      return active.windows.first(where: { $0.isKeyWindow }) ?? active.windows.first
    }
    return scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
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
    if let window = foregroundWindow {
      window.addSubview(host)
      window.bringSubviewToFront(host)
      host.layer.addSublayer(layer)
      self.pipHost = host
    } else {
      // 拿不到窗口时 layer 永远不会上屏，直接报错，避免无意义重试。
      channel.invokeMethod("state", arguments: [
        "active": false,
        "error": "找不到前台窗口，无法挂载视频图层",
      ])
      cleanup()
      return
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
        self.waitForDisplayThenStart()
      }
    }
  }

  /// AVKit 要求 AVPlayerLayer 先完成至少一帧渲染才能启动 PiP；用
  /// isReadyForDisplay 等待渲染完成（带超时兜底）再启动。加密流（红果）
  /// 解密较慢，超时放宽到 15 秒；超时不再强行启动，避免图层未上屏时
  /// 反复触发 -1001。
  private func waitForDisplayThenStart() {
    guard let layer = playerLayer else {
      startPictureInPicture()
      return
    }
    if layer.isReadyForDisplay {
      startPictureInPicture()
      return
    }
    displayToken = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] observed, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.displayToken = nil
        if observed.isReadyForDisplay {
          self.startPictureInPicture()
        }
      }
    }
    // 超时兜底：15 秒后仍未渲染则报错，不再强制启动。
    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
      guard let self else { return }
      if self.displayToken != nil {
        self.displayToken = nil
        self.channel.invokeMethod("state", arguments: [
          "active": false,
          "error": "视频画面未能完成渲染，无法进入画中画",
        ])
        self.cleanup()
      }
    }
  }

  /// 阶梯重试启动 PiP：不依赖 isPictureInPicturePossible（该标志可能很晚才变
  /// true），直接调用 startPictureInPicture，失败通过 delegate 回调记录，靠
  /// 阶梯重试直到窗口真正弹出，规避 -1001。
  private func startPictureInPicture() {
    guard let controller = pipController else { return }
    if controller.isPictureInPictureActive { return }
    // 图层必须真正渲染出画面，AVKit 才允许启动 PiP；未就绪时继续等待，
    // 而不是盲目 startPictureInPicture 触发 -1001。
    if playerLayer?.isReadyForDisplay != true {
      scheduleRetry()
      return
    }
    controller.startPictureInPicture()
    scheduleRetry()
  }

  private func scheduleRetry() {
    let delays: [Double] = [0.35, 0.6, 0.9, 1.2, 1.5, 1.8, 2.2, 2.6]
    guard startAttempt < delays.count else {
      let reason = lastPipError ?? pipDiagnostics()
      channel.invokeMethod("state", arguments: [
        "active": false,
        "error": reason,
      ])
      cleanup()
      return
    }
    let delay = delays[startAttempt]
    startAttempt += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      if self.pipController?.isPictureInPictureActive != true {
        self.startPictureInPicture()
      }
    }
  }

  /// 重试耗尽仍未启动时，把关键状态一起回传，便于定位「场景未激活 / 图层未渲染」等根因。
  private func pipDiagnostics() -> String {
    var parts: [String] = []
    if let controller = pipController {
      parts.append("possible=\(controller.isPictureInPicturePossible)")
    }
    if let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first {
      parts.append("scene=\(scene.activationState.rawValue)")
    }
    parts.append("layerReady=\(playerLayer?.isReadyForDisplay == true)")
    return "系统未能启动画中画（\(parts.joined(separator: ", "))）"
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
    displayToken = nil
    pendingSeek = nil
    startAttempt = 0
    lastPipError = nil
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
    // 返回全屏时把系统 PiP（独立 AVPlayer）的当前进度回传，Flutter 侧据此 seek，
    // 避免回到全屏后播放进度仍停留在进入 PiP 之前的位置。
    let seconds = player?.currentTime().seconds ?? 0
    let positionMs = seconds.isFinite ? seconds * 1000 : 0
    channel.invokeMethod("state", arguments: ["active": false, "positionMs": positionMs])
    cleanup()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    // 不立即 cleanup：保留 player/layer，交给阶梯重试继续尝试；最终失败由
    // scheduleRetry 重试耗尽时统一回传错误并清理。这里记下底层失败原因，
    // 便于把 AVKit 的真实诊断（如场景未激活/图层未上屏）回传给用户定位。
    let ns = error as NSError
    let reason = ns.localizedFailureReason ?? ns.localizedDescription
    lastPipError = "\(reason)（\(ns.domain) \(ns.code)）"
  }
}

// MARK: - 实体音量键提示（监听系统输出音量变化）
final class VolumeKeyWatcher: NSObject {
  private let channel: FlutterMethodChannel
  private var observation: NSKeyValueObservation?
  private var volumeToken: NSObjectProtocol?
  private var suppress = false
  private var lastVolume: Float = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/volume", binaryMessenger: messenger)
    super.init()
    lastVolume = AVAudioSession.sharedInstance().outputVolume
    // 关键：监听 AVSystemController_SystemVolumeDidChangeNotification 私有通知前，
    // 必须先开启远程控制事件接收，否则该通知在部分设备/系统上收不到或飘忽不定，
    // 导致「音量到最大/最小后继续按同一方向」不再弹出音量提示图标。
    UIApplication.shared.beginReceivingRemoteControlEvents()
    // 物理音量键：AVSystemController 私有通知在每次按键时都会触发，即使音量已到
    // 最大/最小值、数值不变；这样在边界继续按音量键也能弹出音量提示图标。
    volumeToken = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self, !self.suppress else { return }
      let reason = note.userInfo?["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String
      guard reason == "ExplicitVolumeChange" else { return }
      let value = AVAudioSession.sharedInstance().outputVolume
      self.lastVolume = value
      self.channel.invokeMethod("changed", arguments: [
        "volume": Double(value),
        "enabled": true,
      ])
    }
    // KVO 兜底：程序内（如 MPVolumeView）或路由变化导致的音量变化。
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
