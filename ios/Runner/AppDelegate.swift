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
  // 预热：前台播放时就建好 AVPlayer/Layer 并渲染就绪，离开时可直接启动 PiP，
  // 避免在 willResignActive 才临时建 layer、等渲染，却因马上进后台而卡住。
  private var prepared = false
  private var preparedUrl: String?
  // 画中画中切集：PiP 激活期间 replaceCurrentItem 不会刷新画面（旧集循环），
  // 需先停 PiP 再用新集重建。换源期间屏蔽 didStop 的正常收尾，避免误把本地
  // 播放器 seek 回旧集进度。
  private var switchingSource = false
  private var pendingSourceSwitch: [String: Any]?
  // 画中画本集播到片尾：监听 AVPlayerItemDidPlayToEndTime，通知 Dart 切下一集。
  // 用户点「前进15秒」把进度推到片尾同样会触发。此前原生播完不做任何事，
  // 导致进度到头后画中画永远停在旧集——这是「切集还是同一集」的真正原因。
  private var endObserver: NSObjectProtocol?
  private var endHandled = false
  private let mediaChannel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/pip", binaryMessenger: messenger)
    mediaChannel = FlutterMethodChannel(name: "duanju/media", binaryMessenger: messenger)
    super.init()
    // 「离开应用时自动画中画」：在 App 即将失去活跃（进入后台/锁屏）的瞬间
    // 启动系统画中画。此时场景仍处于可启动 PiP 的过渡态，成功率最高。
    // layer 已在前台由 armAuto 预热渲染就绪，这里直接启动即可。
    autoObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.autoArmed,
            !(self.pipController?.isPictureInPictureActive ?? false) else { return }
      self.startAuto()
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
      case "switchSource":
        self.switchSource(call.arguments as? [String: Any] ?? [:])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 前台播放中调用：提前建好 AVPlayer/Layer 并渲染就绪（静音待命），
  /// 这样 willResignActive 时可直接启动 PiP，不必等渲染导致卡在后台。
  private func armAuto(_ args: [String: Any]) {
    autoArgs = args
    autoArmed = !args.isEmpty
    guard autoArmed else { return }
    let url = args["url"] as? String ?? ""
    // 地址没变且已预热：只更新进度/倍速，不重建 layer（切集时由 switchSource 换源）。
    // 带 seek 标记让预热 player 的进度跟随本地播放器，离开时从正确位置开播。
    if prepared, preparedUrl == url, player != nil {
      var synced = args
      synced["seek"] = true
      update(synced)
      return
    }
    prepare(args, autoplay: false)
  }

  private func disarmAuto() {
    autoArmed = false
    autoArgs = [:]
    prepared = false
    preparedUrl = nil
    // 未真正进入 PiP 时，回收预热用的播放器/layer。
    if pipController?.isPictureInPictureActive != true {
      cleanup()
    }
  }

  /// 画中画播放中切集。PiP 激活期间直接 replaceCurrentItem 不会刷新画面（PiP 仍
  /// 循环旧帧），因此改为：停掉 PiP → 复用已挂载的 player/layer 换 item → 重启 PiP。
  /// 复用现有 layer 是关键：切集时 App 多在后台，重新 prepare 会拿不到前台窗口。
  /// 原生诊断日志回传 Dart 的 DiaryService，打通原生侧盲区。
  private func diag(_ msg: String) {
    NSLog("[PiPDiag] \(msg)")
    channel.invokeMethod("diag", arguments: msg)
  }

  /// 监听当前 item 播到片尾：通过媒体命令通道发 next，让 Dart 切下一集，
  /// 随后 Dart 的会话变化会触发换源，把画中画切换到新一集。
  private func observeEnd(of item: AVPlayerItem) {
    endObserver?.invalidate()
    endObserver = nil
    endHandled = false
    endObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name.AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self, !self.endHandled else { return }
      self.endHandled = true
      self.diag("画中画本集播到片尾，请求切下一集")
      self.mediaChannel.invokeMethod("command", arguments: ["command": "next"])
    }
  }

  /// 画中画播放中切集：直接在现有 AVPlayer 上替换 item，不停止画中画。
  /// 关键：PiP 激活时 App 多在后台，iOS 不允许在后台重新 start PiP，所以
  /// 「stop→重启」方案停了就起不来。PiP 绑定的是同一个 player，替换 item
  /// 后会随新集渲染。此前「换源不生效」的真正原因是切集命令没到达（媒体控制
  /// 被释放），并非直接换 item 不行——该方案现在才第一次真正被执行。
  private func switchSource(_ args: [String: Any]) {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          args["url"] as? String != nil else { return }
    diag("switchSource 进入 pipActive=\(pipController?.isPictureInPictureActive ?? false)")
    // replaceItem 内部会 invalidate 上一次未就绪的 KVO，快速连点自动收敛到最后一次。
    replaceItem(args, restartPip: false)
  }

  /// 完成换源：用最新目标集换 item 并重启 PiP。由 didStop 回调或超时兜底触发。
  private func finishSourceSwitch() {
    guard switchingSource else { return }
    switchingSource = false
    let args = pendingSourceSwitch ?? [:]
    pendingSourceSwitch = nil
    replaceItem(args, restartPip: true)
  }

  /// 用新集 URL 替换当前 item，复用现有 player/layer/pipController（不重新挂载窗口）。
  private func replaceItem(_ args: [String: Any], restartPip: Bool) {
    guard let urlString = args["url"] as? String,
          let url = URL(string: urlString),
          let player else { return }
    diag("replaceItem 开始 url长度=\(urlString.count) restartPip=\(restartPip)")
    var options: [String: Any] = [:]
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
    lastRate = rate > 0 ? rate : 1
    let position = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
    kvoToken?.invalidate()
    kvoToken = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        switch observed.status {
        case .readyToPlay:
          self.diag("新集 readyToPlay，replaceCurrentItem")
          self.kvoToken = nil
          self.playerItem = item
          self.preparedUrl = urlString
          self.observeEnd(of: item)
          player.replaceCurrentItem(with: item)
          // PiP 中换源需取消静音并以 rate>0 播放，新一集才会真正渲染出画面。
          player.isMuted = false
          item.seek(to: CMTime(value: Int64(position), timescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
              guard let self else { return }
              player.rate = Float(self.lastRate)
              self.diag("新集已 seek 并 rate=\(self.lastRate) 播放，pipActive=\(self.pipController?.isPictureInPictureActive ?? false)")
              if restartPip { self.startPictureInPicture() }
            }
          }
        case .failed:
          self.kvoToken = nil
          let message = observed.error?.localizedDescription ?? "新一集加载失败"
          self.diag("新集加载失败: \(message)")
          self.channel.invokeMethod("state", arguments: ["active": false, "error": message])
        default:
          break
        }
      }
    }
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

  /// 手动点画中画按钮：完整准备并立即启动 PiP。
  private func enter(_ args: [String: Any]) {
    prepare(args, autoplay: true)
  }

  /// App 即将失活时启动预热的 PiP：layer 已在前台渲染就绪，直接开播。
  private func startAuto() {
    guard let player, prepared else {
      // 预热尚未完成（例如刚进入播放就立刻离开），降级走完整启动流程。
      enter(autoArgs)
      return
    }
    prepareAudio()
    // 预热时是静音渲染的，真正进入 PiP 前必须取消静音，否则画中画没声音。
    player.isMuted = false
    player.rate = Float(lastRate)
    startPictureInPicture()
  }

  /// 准备独立 AVPlayer/Layer。autoplay=false 时只预热渲染、静音待命，
  /// 供 willResignActive 时秒开；autoplay=true 时渲染完成后立即启动 PiP。
  private func prepare(_ args: [String: Any], autoplay: Bool) {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          let urlString = args["url"] as? String,
          let url = URL(string: urlString) else {
      channel.invokeMethod("state", arguments: ["active": false, "error": "当前设备不支持系统画中画"])
      return
    }
    cleanup()
    prepared = false
    preparedUrl = urlString
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
    self.observeEnd(of: item)

    if #available(iOS 15.0, *),
       let controller = AVPictureInPictureController(playerLayer: layer) {
      controller.delegate = self
      // 双保险：交给系统在离开 App 时自动启动 PiP（Apple 官方机制，时机最可靠），
      // 同时保留 willResignActive 的手动 startAuto 作为兜底。两者都以
      // isPictureInPictureActive 去重，不会重复启动。
      controller.canStartPictureInPictureAutomaticallyFromInline = true
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
      seekAndStart(item, newPlayer, autoplay: autoplay)
    } else {
      kvoToken = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
        DispatchQueue.main.async {
          guard let self else { return }
          switch observed.status {
          case .readyToPlay:
            self.kvoToken = nil
            self.seekAndStart(item, newPlayer, autoplay: autoplay)
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

  private func seekAndStart(_ item: AVPlayerItem, _ newPlayer: AVPlayer, autoplay: Bool) {
    let time = pendingSeek ?? .zero
    pendingSeek = nil
    item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        // 关键：AVPlayer 必须以 rate>0 真正播放，AVPlayerLayer 才会渲染出首帧，
        // isReadyForDisplay 才会变 true，PiP 才可能启动。rate=0 永远不会渲染，
        // 这正是上一版「离开后画中画完全不出现」的根因。
        // 预热模式（autoplay=false）改用 isMuted 静音：既渲染画面，又不与本地播放器双重出声。
        newPlayer.rate = Float(self.lastRate)
        newPlayer.isMuted = !autoplay
        self.waitForDisplayThenStart(autoplay: autoplay)
      }
    }
  }

  /// AVKit 要求 AVPlayerLayer 先完成至少一帧渲染才能启动 PiP；用
  /// isReadyForDisplay 等待渲染完成（带超时兜底）再启动。加密流（红果）
  /// 解密较慢，超时放宽到 15 秒；超时不再强行启动，避免图层未上屏时
  /// 反复触发 -1001。
  private func waitForDisplayThenStart(autoplay: Bool) {
    guard let layer = playerLayer else {
      if autoplay { startPictureInPicture() } else { prepared = true }
      return
    }
    // 预热模式下图层就绪即标记完成，不启动 PiP；离开时由 startAuto 直接启动。
    let onReady = { [weak self] in
      guard let self else { return }
      if autoplay {
        self.startPictureInPicture()
      } else {
        self.prepared = true
      }
    }
    if layer.isReadyForDisplay {
      onReady()
      return
    }
    displayToken = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] observed, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if observed.isReadyForDisplay {
          self.displayToken = nil
          onReady()
        }
      }
    }
    // 超时兜底：预热模式静默失败（离开时可降级重试）；手动启动则报错。
    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
      guard let self else { return }
      if self.displayToken != nil {
        self.displayToken = nil
        if autoplay {
          self.channel.invokeMethod("state", arguments: [
            "active": false,
            "error": "视频画面未能完成渲染，无法进入画中画",
          ])
          self.cleanup()
        }
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
    // 用户主动退出：清除换源标志，避免切集中途退出时被 didStop 误判为换源而重启。
    switchingSource = false
    pendingSourceSwitch = nil
    pipController?.stopPictureInPicture()
    cleanup()
  }

  private func cleanup() {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    endHandled = false
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    timeObserver = nil
    kvoToken = nil
    displayToken = nil
    pendingSeek = nil
    startAttempt = 0
    lastPipError = nil
    prepared = false
    preparedUrl = nil
    switchingSource = false
    pendingSourceSwitch = nil
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
    // PiP 真正启动的统一回调点：系统自动启动与手动 startAuto 都会经过这里。
    // 预热阶段是静音渲染的，这里统一取消静音，确保画中画有声音。
    player?.isMuted = false
    channel.invokeMethod("state", arguments: ["active": true])
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    // 切集导致的停止：不回传结束状态（否则 Dart 会把本地播放器恢复并把进度
    // seek 回旧集），直接用新集重建并重启 PiP。
    if switchingSource {
      finishSourceSwitch()
      return
    }
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
  private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
  private var resetWork: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/volume", binaryMessenger: messenger)
    super.init()
    lastVolume = AVAudioSession.sharedInstance().outputVolume
    // 关键：监听 AVSystemController_SystemVolumeDidChangeNotification 私有通知前，
    // 必须先开启远程控制事件接收，否则该通知在部分设备/系统上收不到或飘忽不定。
    UIApplication.shared.beginReceivingRemoteControlEvents()
    // 物理音量键：只要收到系统音量变化通知就弹图标，不再依赖 reason 字段
    // （音量到最大/最小后继续按同方向时，reason 可能不再是 ExplicitVolumeChange）。
    volumeToken = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, !self.suppress else { return }
      let value = AVAudioSession.sharedInstance().outputVolume
      self.lastVolume = value
      self.emit(value)
      self.scheduleBoundaryResetIfNeeded(value)
    }
    // KVO 兜底：程序内（如 MPVolumeView）或路由变化导致的音量变化。
    observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
      guard let self else { return }
      let value = session.outputVolume
      if abs(value - self.lastVolume) < 0.001 { return }
      self.lastVolume = value
      if self.suppress { return }
      self.emit(value)
      self.scheduleBoundaryResetIfNeeded(value)
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

  private func emit(_ value: Float) {
    channel.invokeMethod("changed", arguments: [
      "volume": Double(value),
      "enabled": true,
    ])
  }

  /// 音量到顶/到底后，系统不再改变音量，继续按同方向实体键不会再发
  /// `AVSystemController_SystemVolumeDidChangeNotification`。这里在到达边界的瞬间
  /// 安排一次「往内微调一档」，保证下一次按键仍能触发通知、弹出音量提示图标。
  private func scheduleBoundaryResetIfNeeded(_ value: Float) {
    guard value >= 0.995 || value <= 0.005 else { return }
    resetWork?.cancel()
    let target: Float = value >= 0.995 ? 0.97 : 0.03
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.suppress = true
      self.setSystemVolume(target)
      self.lastVolume = target
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.suppress = false
      }
    }
    resetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  private func setSystemVolume(_ value: Float) {
    installVolumeView()
    if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
      slider.value = value
    }
  }

  private func installVolumeView() {
    if volumeView.superview != nil { return }
    if let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) {
      window.addSubview(volumeView)
    }
  }
}
