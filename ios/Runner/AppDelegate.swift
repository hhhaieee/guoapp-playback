import Flutter
import UIKit
import DuanjuCore
import CFNetwork
import AVFoundation
import AVKit
import CoreMedia
import MediaPlayer
import LocalAuthentication

/// 播放器/画中画激活 .playback 会话时广播：会话切换会让 outputVolume 跳变，
/// 这不是用户按音量键。VolumeKeyWatcher 据此开静默窗口吞掉跳变，避免刚进
/// 视频图标自己弹出；静默从「会话激活时刻」算，而非进页面时刻。
private let volumeSessionWillActivate = Notification.Name("duanju/volume/sessionWillActivate")
private func notifyVolumeSessionWillActivate() {
  NotificationCenter.default.post(name: volumeSessionWillActivate, object: nil)
}

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

  /// 只在播放器内抑制系统音量 HUD（把 MPVolumeView 挂到屏幕外），
  /// 其余页面放开系统 HUD，由 iOS 自己弹出音量图标。
  private func setSystemHudSuppressed(_ suppressed: Bool) {
    if suppressed {
      guard volumeView.superview == nil, let window = keyWindow else { return }
      window.addSubview(volumeView)
    } else {
      volumeView.removeFromSuperview()
    }
  }

  /// 通过 MPVolumeView 的 slider 设置系统媒体音量（App 手势调音量 / 音量边界重置用）。
  private func setSystemVolume(_ value: Float) {
    if volumeView.superview == nil { keyWindow?.addSubview(volumeView) }
    let slider = volumeView.subviews.first { $0 is UISlider } as? UISlider
    slider?.value = min(max(value, 0), 1)
  }

  private func applyAlternateIcon(_ name: String?, result: @escaping FlutterResult) {
    let finish: (Error?) -> Void = { error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(code: "icon_switch_failed", message: error.localizedDescription, details: nil))
        } else {
          result(nil)
        }
      }
    }
    let selector = NSSelectorFromString("_setAlternateIconName:withCompletionHandler:")
    if UIApplication.shared.responds(to: selector) {
      typealias PrivateMethod = @convention(c) (UIApplication, Selector, NSString?, Any?) -> Void
      let implementation = UIApplication.shared.method(for: selector)
      let method = unsafeBitCast(implementation, to: PrivateMethod.self)
      let completion: @convention(block) (NSError?) -> Void = { error in finish(error) }
      method(UIApplication.shared, selector, name as NSString?, completion)
    } else {
      UIApplication.shared.setAlternateIconName(name) { error in finish(error) }
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
      volumeWatcher = VolumeKeyWatcher(
        messenger: registrar.messenger(),
        setSystemHudSuppressed: { [weak self] in self?.setSystemHudSuppressed($0) },
        setSystemVolume: { [weak self] value in self?.setSystemVolume(value) },
      )
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
            self.setSystemVolume(Float(value))
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
        case "setLauncherIcon":
          let icon = (arguments?["name"] as? String) ?? "star"
          self.applyAlternateIcon(icon == "star" ? nil : icon, result: result)
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
      // 会话激活会令 outputVolume 跳变（非物理按键）：先广播，让音量监听开静默窗口吞掉。
      notifyVolumeSessionWillActivate()
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
    try? AVAudioSession.sharedInstance().setActive(false)
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
  private var displayToken: NSKeyValueObservation?
  // 手动点按钮（前台）启动 PiP 时置 true，用于区分系统自动启动的失败：
  // 手动失败才回传错误置灰，系统自动失败静默（后台用户看不到，交给系统自行处理）。
  private var manualEnter = false
  // 切后台兜底监听 token：图层已预热就绪时主动补调一次启动，弥补系统自动
  // canStartPictureInPictureAutomaticallyFromInline 对隐藏假图层不认、不触发的问题。
  private var autoStartToken: NSObjectProtocol?
  // 预热：前台播放时就建好 AVPlayer/Layer 并渲染就绪，离开时可直接启动 PiP，
  // 避免在 willResignActive 才临时建 layer、等渲染，却因马上进后台而卡住。
  private var prepared = false
  private var preparedUrl: String?
  // PiP 内播放/暂停意图：KVO 持续跟踪 player.rate，didStop 时回传该值，
  // 避免系统停止 PiP 时暂存 rate 导致状态同步失败。
  private var pipPlaying = true
  private var rateObservation: NSKeyValueObservation?
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
    // 自动画中画双保险：
    // ① prepare() 里设置 canStartPictureInPictureAutomaticallyFromInline = true，
    //    由 iOS 官方机制在离开 App 时自动提升为 PiP（首选，时机最可靠）。
    // ② 监听 willResignActive 做兜底：系统自动机制对「隐藏的假图层」可能不认、
    //    不触发（本项目中 2×2 极透明图层就属于这种情况）。图层若已在前台预热
    //    渲染就绪，此时直接调一次启动，成功率和手动按钮同级。
    // 两层用 isPictureInPictureActive 去重，谁先成功都不重复启动；兜底失败由
    // delegate 静默处理（manualEnter=false 时不回传、不置灰），不打扰用户。
    autoStartToken = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self,
            self.prepared,
            !self.manualEnter,
            self.pipController?.isPictureInPictureActive != true else { return }
      self.startPictureInPicture()
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
  /// 让系统 canStartPictureInPictureAutomaticallyFromInline 在离开 App 时可秒开。
  private func armAuto(_ args: [String: Any]) {
    manualEnter = false
    guard !args.isEmpty else { return }
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
    prepared = false
    preparedUrl = nil
    // 未真正进入 PiP 时，回收预热用的播放器/layer。
    if pipController?.isPictureInPictureActive != true {
      cleanup()
    }
  }

  /// 监听当前 item 播到片尾：通过媒体命令通道发 next，让 Dart 切下一集，
  /// 随后 Dart 的会话变化会触发换源，把画中画切换到新一集。
  private func observeEnd(of item: AVPlayerItem) {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    endHandled = false
    endObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name.AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self, !self.endHandled else { return }
      self.endHandled = true
      self.mediaChannel.invokeMethod("command", arguments: ["command": "next"])
    }
  }

  /// 画中画播放中切集：直接在现有 AVPlayer 上替换 item，不停止画中画。
  /// PiP 激活时 App 多在后台，iOS 不允许在后台重启 PiP，故复用同一个 player，
  /// 替换 item 后随新集渲染。此前「换源不生效」的根因是切集命令没到达（媒体
  /// 控制被释放），并非直接换 item 不行。
  private func switchSource(_ args: [String: Any]) {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          args["url"] as? String != nil else { return }
    // replaceItem 内部会 invalidate 上一次未就绪的 KVO，快速连点自动收敛到最后一次。
    replaceItem(args)
  }

  /// 用新集 URL 替换当前 item，复用现有 player/layer/pipController（不重新挂载窗口）。
  private func replaceItem(_ args: [String: Any]) {
    guard let urlString = args["url"] as? String,
          let url = URL(string: urlString),
          let player else { return }
    kvoToken?.invalidate()
    kvoToken = nil
    var options: [String: Any] = [:]
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
    lastRate = rate > 0 ? rate : 1
    let position = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0

    // 关键修复：AVPlayerItem 必须先交给 AVPlayer 才会开始加载资源、status 才可能
    // 变成 .readyToPlay。之前先等 .readyToPlay 再 replaceCurrentItem，孤立的 item
    // 永远是 .unknown，KVO 回调永不触发 —— 这正是「换源卡住、一直播旧集」的根因。
    self.playerItem = item
    self.preparedUrl = urlString
    self.observeEnd(of: item)
    player.replaceCurrentItem(with: item)
    player.isMuted = false

    let playbackRate = self.lastRate
    let startPlayback = {
      item.seek(to: CMTime(value: Int64(position), timescale: 1000),
                toleranceBefore: .zero, toleranceAfter: .zero) { _ in
        DispatchQueue.main.async {
          player.rate = Float(playbackRate)
        }
      }
    }

    // 与 prepare 一致：先查一次当前状态，避免已是 readyToPlay 却因 KVO 只监听
    // 后续变化而漏掉；未就绪才挂 KVO 等待。
    if item.status == .readyToPlay {
      startPlayback()
    } else {
      kvoToken = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
        DispatchQueue.main.async {
          guard let self else { return }
          switch observed.status {
          case .readyToPlay:
            self.kvoToken = nil
            startPlayback()
          case .failed:
            self.kvoToken = nil
            let message = observed.error?.localizedDescription ?? "新一集加载失败"
            self.channel.invokeMethod("state", arguments: ["active": false, "error": message])
          default:
            break
          }
        }
      }
    }
  }

  private func prepareAudio() {
    let session = AVAudioSession.sharedInstance()
    // PiP 激活会话同样会让 outputVolume 跳变，通知音量监听吞掉，避免误弹图标。
    notifyVolumeSessionWillActivate()
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

  /// 手动点画中画按钮：完整准备并立即启动 PiP（前台时机，成功率高）。
  private func enter(_ args: [String: Any]) {
    manualEnter = true
    prepare(args, autoplay: true)
  }

  /// 准备独立 AVPlayer/Layer。autoplay=false 时由 armAuto 预热渲染、静音待命，
  /// 交给系统 canStartPictureInPictureAutomaticallyFromInline 在离开 App 时自动启动；
  /// autoplay=true 时（手动按钮）渲染完成后立即启动 PiP。
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
      // 自动画中画唯一入口：交给系统在离开 App 时启动（Apple 官方机制，
      // 由系统掌握最佳时机，成功率最高）。预热 layer 已在前台渲染就绪，
      // 系统据此在切后台时自动提升为 PiP。
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
    // 预热模式下图层就绪即标记完成，由系统在离开 App 时自动启动 PiP。
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

  /// 手动按钮启动 PiP（前台时机）。图层已渲染出首帧才调用，避免 -1001。
  /// 自动 PiP 不走这里：由系统 canStartPictureInPictureAutomaticallyFromInline
  /// 在最合适的时机自行启动，成功率远高于手动抢 willResignActive 过渡态。
  private func startPictureInPicture() {
    guard let controller = pipController,
          !controller.isPictureInPictureActive,
          playerLayer?.isReadyForDisplay == true else { return }
    controller.startPictureInPicture()
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
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    endHandled = false
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    timeObserver = nil
    rateObservation?.invalidate()
    rateObservation = nil
    kvoToken = nil
    displayToken = nil
    pendingSeek = nil
    prepared = false
    preparedUrl = nil
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
  /// KVO 持续跟踪 PiP 内 AVPlayer 的播放/暂停（小窗播放按钮直接改 rate）。
  /// 实时回传让控制中心状态与画中画一致；didStop 时回传最后的 pipPlaying，
  /// 避免系统停止 PiP 时暂存 rate 导致返回后状态同步失败。
  private func startRateObservation() {
    rateObservation?.invalidate()
    rateObservation = nil
    guard let player else { return }
    pipPlaying = player.rate > 0
    rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] observed, _ in
      guard let self else { return }
      let playing = observed.rate > 0
      self.pipPlaying = playing
      self.channel.invokeMethod("pipPlaying", arguments: ["playing": playing])
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    // PiP 真正启动的统一回调点：系统自动启动与手动按钮都会经过这里。
    // 预热阶段是静音渲染的，这里统一取消静音，确保画中画有声音。
    player?.isMuted = false
    startRateObservation()
    channel.invokeMethod("state", arguments: ["active": true])
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    // 返回全屏时把系统 PiP（独立 AVPlayer）的进度和最后播放状态回传，Flutter 侧
    // 据此 seek 并延续画中画的播放/暂停：在播→续播，暂停→保持暂停。
    // playing 取 KVO 持续跟踪的 pipPlaying，而非此刻 rate——系统停止 PiP 时
    // 可能已把 rate 归零，当场读取会误判为「已暂停」，导致返回后不续播。
    let seconds = player?.currentTime().seconds ?? 0
    let positionMs = seconds.isFinite ? seconds * 1000 : 0
    channel.invokeMethod("state", arguments: [
      "active": false,
      "positionMs": positionMs,
      "playing": pipPlaying,
    ])
    cleanup()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    // 自动 PiP（系统后台启动）失败：静默处理，不打断用户、不置灰按钮——
    // 系统可能在后续时机自行重试成功，抢报失败只会误伤。
    guard manualEnter else { return }
    // 手动按钮（前台）失败：回传错误，由页面把按钮置灰。
    let ns = error as NSError
    let reason = ns.localizedFailureReason ?? ns.localizedDescription
    channel.invokeMethod("state", arguments: [
      "active": false,
      "error": "\(reason)（\(ns.domain) \(ns.code)）",
    ])
    cleanup()
  }

  deinit {
    if let token = autoStartToken {
      NotificationCenter.default.removeObserver(token)
    }
  }
}

// MARK: - 实体音量键提示（仅播放器内自绘，其余页面交给系统 HUD）
final class VolumeKeyWatcher: NSObject {
  private let channel: FlutterMethodChannel
  private var observation: NSKeyValueObservation?
  private var volumeToken: NSObjectProtocol?
  private var sessionToken: NSObjectProtocol?
  private let setSystemHudSuppressed: (Bool) -> Void
  private let setSystemVolume: (Float) -> Void
  private var playerActive = false
  private var suppress = false
  private var lastVolume: Float = 0
  // 静默期：吸收音频会话激活导致的 outputVolume 跳变（非物理按键），避免
  // "刚进播放器图标就自己跳出来"。静默期内只更新基准值，不弹自绘图标。
  private var quietUntil: Date = .distantPast
  // 到音量上/下限后系统不再改变 outputVolume，继续按同方向键不会再发通知。
  // 到边界时安排一次「往内微调一档」，保证下一次同方向按键仍能触发提示。
  private var boundaryResetWork: DispatchWorkItem?
  // 微调本身引起的音量变化用独立时间戳吞掉，避免与 App 手势调音量的 suppress 冲突。
  private var boundarySuppressUntil: Date = .distantPast

  init(
    messenger: FlutterBinaryMessenger,
    setSystemHudSuppressed: @escaping (Bool) -> Void,
    setSystemVolume: @escaping (Float) -> Void
  ) {
    channel = FlutterMethodChannel(name: "duanju/volume", binaryMessenger: messenger)
    self.setSystemHudSuppressed = setSystemHudSuppressed
    self.setSystemVolume = setSystemVolume
    super.init()
    lastVolume = AVAudioSession.sharedInstance().outputVolume
    // 开启远程控制事件接收：AVSystemController 私有通知作为 KVO 之外的补充触发，
    // 但该通知在 .playback 会话下不稳定（曾因只依赖它导致视频内图标不弹），
    // 因此主信号仍是下面的 outputVolume KVO。
    UIApplication.shared.beginReceivingRemoteControlEvents()
    volumeToken = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, self.playerActive else { return }
      self.onVolumeChanged(AVAudioSession.sharedInstance().outputVolume)
    }
    // 会话激活（setCategory/setActive）会让 outputVolume 跳变，这不是物理按键。
    // 播放器/PiP 在激活会话前广播此通知，我们据此开 1.2s 静默窗口吞掉跳变。
    // 关键：静默从「会话激活时刻」算，而非进页面时刻——跳变就发生在激活瞬间，
    // 这样既能彻底误弹，又不影响之后用户真实按键弹图标。
    sessionToken = NotificationCenter.default.addObserver(
      forName: volumeSessionWillActivate, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.quietUntil = Date().addingTimeInterval(1.2)
      self.lastVolume = AVAudioSession.sharedInstance().outputVolume
    }
    // KVO 是物理音量键最可靠的信号（AVSystemController 私有通知在 .playback
    // 会话下并不可靠，不能作为唯一来源）。恢复据此弹图标，配合上面的会话静默
    // 窗口区分「会话跳变」与「真实按键」：跳变被静默吞掉，按键正常弹出。
    observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
      guard let self, self.playerActive else { return }
      self.onVolumeChanged(session.outputVolume)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "setPlayerMode":
        let args = call.arguments as? [String: Any] ?? [:]
        let active = args["active"] as? Bool ?? false
        let hudEnabled = args["hud"] as? Bool ?? true
        let useCustomHud = active && hudEnabled
        self.playerActive = useCustomHud
        self.lastVolume = AVAudioSession.sharedInstance().outputVolume
        // 只留极短的 0.3s 切页残留吸收；真正的会话激活跳变由 volumeSessionWillActivate
        // 通知开的静默窗口覆盖（从激活时刻算，而非进页面时刻）。不设过长静默，
        // 否则进播放器后马上按音量键会被误吞。退出播放器恢复即时响应。
        self.quietUntil = useCustomHud
          ? Date().addingTimeInterval(0.3)
          : .distantPast
        self.setSystemHudSuppressed(useCustomHud)
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

  /// KVO 与私有通知的统一入口：静默期/抑制态只更新基准，不弹图标。
  private func onVolumeChanged(_ value: Float) {
    if abs(value - lastVolume) < 0.001 { return }
    lastVolume = value
    guard Date() >= quietUntil, Date() >= boundarySuppressUntil, !suppress else { return }
    emit(value)
    scheduleBoundaryResetIfNeeded(value)
  }

  /// 音量到顶/到底后，系统不再改变 outputVolume，继续按同方向键不会再触发
  /// KVO/通知。这里在到达边界的瞬间安排一次「往内微调一档」，保证下一次同
  /// 方向按键仍能改变音量、从而弹出提示图标。微调本身用独立抑制窗口吞掉，不弹图标。
  private func scheduleBoundaryResetIfNeeded(_ value: Float) {
    guard value >= 0.995 || value <= 0.005 else { return }
    boundaryResetWork?.cancel()
    let target: Float = value >= 0.995 ? 0.97 : 0.03
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.playerActive else { return }
      // 先开独立抑制窗口，再微调，避免这次微调被当成用户按键弹图标。
      self.boundarySuppressUntil = Date().addingTimeInterval(0.4)
      self.setSystemVolume(target)
      self.lastVolume = target
    }
    boundaryResetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  private func emit(_ value: Float) {
    channel.invokeMethod("changed", arguments: ["volume": Double(value)])
  }
}
