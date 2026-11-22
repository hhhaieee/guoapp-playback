import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../app_device.dart';
import '../../diary_service.dart';
import '../../ios_picture_in_picture.dart';
import '../../local_store.dart';
import '../../picture_in_picture.dart';
import '../../playback_session.dart';
import '../../volume_keys_hud.dart';
import '../app_scope.dart';
import 'audio_player_page.dart';
import 'landscape_player_page.dart';
import 'mini_player.dart';
import 'playback_handle.dart';
import 'player_page.dart';
import 'portrait_player_page.dart';
import 'television_player_page.dart';
import 'window_fullscreen.dart';

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key, required this.store, required this.handle});
  final LocalStore store;
  final PlaybackHandle handle;

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  final _padFullscreen = ValueNotifier(false);
  bool _windowFullscreen = false;
  final _pageScope = FocusScopeNode(debugLabel: 'playbackPage');
  final _pip = PictureInPicture.instance;
  final _iosPip = IosPictureInPicture.instance;
  String? _autoPipSession;
  String? _autoPipUrl;
  Map<String, String> _autoPipHeaders = const {};
  bool _autoPipArmed = false;
  bool _autoPipSyncing = false;
  // 画中画独立播放器当前正在播放的媒体会话，用于检测切集并换源。
  String? _pipSourceSession;
  bool _pipSwitching = false;
  late bool _wideVideo = _measure();
  late bool _audio = _session.audio;
  MediaQueryData? _media;
  bool _shown = false;
  bool _locked = false;
  Player? _bound;
  StreamSubscription<bool>? _playing;

  PlaybackSession get _session => widget.handle.session;

  bool _measure() =>
      _session.aspectKnown && _session.aspectRatio >= 1 && !_session.audio;

  bool get _television =>
      AppScope.formFactorOf(context) == FormFactor.television;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _padFullscreen.addListener(_padFullscreenChanged);
    _pip.addListener(_pipChanged);
    _pip.onAction = _action;
    _iosPip.onState = _iosPipState;
    _iosPip.onAction = _action;
    _iosPip.addListener(_iosPipChanged);
    _bind();
    VolumeKeysHud.instance.setEnabled(
      widget.store.playbackPreferences.volumeKeysHud,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _pip.removeListener(_pipChanged);
    if (_pip.onAction == _action) _pip.onAction = null;
    if (_iosPip.onAction == _action) _iosPip.onAction = null;
    if (_iosPip.onState == _iosPipState) _iosPip.onState = null;
    _iosPip.removeListener(_iosPipChanged);
    unawaited(_iosPip.disarmAuto());
    _pip.clear();
    if (_pip.window) unawaited(_restore());
    unawaited(_playing?.cancel());
    _pageScope.dispose();
    if (_padFullscreen.value) _applyPadFullscreen(false);
    _padFullscreen.dispose();
    unawaited(AppDevice.resetBrightness());
    VolumeKeysHud.instance.setEnabled(false);
    widget.handle.dispose();
    super.dispose();
  }

  void _changed() {
    _bind();
    _sync();
    final wide = _measure();
    final audio = _session.audio;
    if (wide != _wideVideo || audio != _audio) {
      setState(() {
        _wideVideo = wide;
        _audio = audio;
      });
    }
    if (_session.locked != _locked) {
      _locked = _session.locked;
      _holdOrientation(_locked);
    }
  }

  void _holdOrientation(bool locked) {
    if (desktopPlatform) return;
    if (!locked) {
      unawaited(AppDevice.releaseHeldOrientation());
      return;
    }
    final landscape =
        (_media ?? MediaQuery.of(context)).orientation == Orientation.landscape;
    unawaited(AppDevice.holdOrientation(landscape: landscape));
  }

  void _bind() {
    final player = _session.player;
    if (identical(player, _bound)) return;
    _bound = player;
    unawaited(_playing?.cancel());
    _playing = player.stream.playing.listen((_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    final session = _session;
    final playing = session.player.state.playing;
    _pip.update(
      aspectRatio: session.aspectRatio,
      playing: playing,
      hasPrevious: session.hasPrevious,
      hasNext: session.hasNext,
      autoEnter:
          playing &&
          !_television &&
          !_audio &&
          widget.store.playbackPreferences.autoPictureInPicture,
    );
    _pip.resize(session.aspectRatio);
    // 系统 PiP 播放中切集：本地播放器已换到新集，独立 AVPlayer 还停在旧集，
    // 需要用新一集的流地址换源，否则画中画一直重复播放旧的一集。
    if (_iosPip.active &&
        session.mediaSession.isNotEmpty &&
        session.mediaSession != _pipSourceSession) {
      DiaryService.add('[PiP诊断] 检测到切集: active=true session=${session.mediaSession} 基准=$_pipSourceSession → 触发换源');
      unawaited(_switchPipSource());
    }
    // 系统 PiP 期间，本地播放器已暂停（画面交给独立 AVPlayer 播放），
    // 不把本地暂停状态回写，否则会把 PiP 一起暂停。
    unawaited(_syncAutoPip());
  }

  /// 画中画播放中切集：解析新一集的流地址并让独立 AVPlayer 换源。
  Future<void> _switchPipSource() async {
    if (_pipSwitching) return;
    _pipSwitching = true;
    try {
      final session = _session;
      final mediaSession = session.mediaSession;
      DiaryService.add('[PiP诊断] _switchPipSource进入: mediaSession=$mediaSession 基准=$_pipSourceSession mounted=$mounted active=${_iosPip.active}');
      if (mediaSession.isEmpty || mediaSession == _pipSourceSession) return;
      final resolved = await _resolvePipUrl();
      DiaryService.add('[PiP诊断] 解析地址: url长度=${resolved.url.length} active=${_iosPip.active}');
      if (!mounted || !_iosPip.active) return;
      if (resolved.url.isEmpty) return;
      // 记录目标会话，避免重复换源；换源失败时原生会回调错误。
      _pipSourceSession = mediaSession;
      DiaryService.add('[PiP诊断] 调用原生switchSource换源 → $mediaSession');
      await _iosPip.switchSource(
        url: resolved.url,
        headers: resolved.headers,
        positionMs: 0,
        rate: session.speed,
      );
    } finally {
      _pipSwitching = false;
    }
  }

  void _iosPipChanged() {
    if (mounted) setState(() {});
  }

  void _iosPipState(bool active, {String? error, double? positionMs}) {
    if (!mounted) return;
    final foreground = playerVisible(WidgetsBinding.instance.lifecycleState);
    // 画中画期间保留系统媒体控制，控制中心/线控的切集命令才能送达 App。
    _session.setPipActive(active);
    if (active) {
      // 记录 PiP 独立播放器正在播放的会话，作为切集换源的基准。
      _pipSourceSession = _session.mediaSession;
      // 系统 PiP 启动：本地播放器交给 PiP 的独立 AVPlayer，暂停原画面。
      // 用幂等的 player.pause() 而非 togglePlayback()，避免 playOrPause 与
      // setForeground 的暂停竞争，导致原画面与画中画同时播放。
      _session.setForeground(false);
      if (_session.player.state.playing) unawaited(_session.player.pause());
    } else {
      // PiP 结束：先把 PiP 的进度同步回本地播放器，再按前台状态恢复播放。
      if (foreground && positionMs != null && positionMs > 0) {
        unawaited(() async {
          await _session.seekTo(Duration(milliseconds: positionMs.round()));
          if (mounted) _session.setForeground(foreground);
        }());
      } else {
        _session.setForeground(foreground);
      }
    }
    if (!active && error != null && error.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('画中画启动失败：$error')));
    }
    setState(() {});
  }

  void _pipChanged() {
    if (!mounted) return;
    final shown = _pip.shown;
    if (shown && !_shown) _closeRoutesAbove();
    if (!shown && _shown) _pageScope.requestFocus();
    _shown = shown;
    if (!_television) {
      _session.setForeground(
        playerVisible(WidgetsBinding.instance.lifecycleState),
      );
    }
    _sync();
    setState(() {});
  }

  void _closeRoutesAbove() {
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) return;
    Navigator.of(context).popUntil((other) => other == route);
  }

  void _action(String action) {
    DiaryService.add('[PiP诊断] 收到控制动作: $action (PiP active=${_iosPip.active})');
    switch (action) {
      case 'toggle':
        _session.togglePlayback();
      case 'previous':
        unawaited(_session.previous());
      case 'next':
        unawaited(_session.next());
    }
  }

  /// 解析画中画播放地址。加密源（如红果 CENC）的 AVPlayer 无法用
  /// decryption_key 自行解密，需向本地核心申请已解密的独立流地址。
  /// [cache] 为 true 时按 mediaSession 复用已申请的解密流（供自动画中画
  /// 高频刷新使用，避免每次都新建会话）。
  Future<({String url, Map<String, String> headers})> _resolvePipUrl({
    bool cache = false,
  }) async {
    final session = _session;
    final url = session.mediaUrl;
    if (url == null || url.isEmpty) {
      return (url: '', headers: const <String, String>{});
    }
    if (session.mediaDecryptionKey.isNotEmpty &&
        session.mediaSession.isNotEmpty) {
      if (cache &&
          _autoPipSession == session.mediaSession &&
          _autoPipUrl != null &&
          _autoPipUrl!.isNotEmpty) {
        return (url: _autoPipUrl!, headers: _autoPipHeaders);
      }
      try {
        final plan = await session.repository.pipStream(session.mediaSession);
        if (plan.url.isNotEmpty) {
          if (cache) {
            _autoPipSession = session.mediaSession;
            _autoPipUrl = plan.url;
            _autoPipHeaders = plan.headers;
          }
          return (url: plan.url, headers: plan.headers);
        }
      } catch (_) {
        // 降级：继续用原地址尝试（可能无法解密）。
      }
    }
    return (url: url, headers: session.mediaHeaders);
  }

  /// 「离开应用时自动画中画」：播放中把当前参数告知原生，App 进入后台时
  /// 由原生在 willResignActive 时机自动启动系统画中画。
  Future<void> _syncAutoPip() async {
    if (_autoPipSyncing) return;
    _autoPipSyncing = true;
    try {
      if (!mounted) return;
      final session = _session;
      final shouldArm =
          widget.store.playbackPreferences.autoPictureInPicture &&
          session.player.state.playing &&
          !_television &&
          !_audio &&
          _iosPip.supported &&
          !_iosPip.active;
      if (!shouldArm) {
        if (_autoPipArmed) {
          _autoPipArmed = false;
          await _iosPip.disarmAuto();
        }
        return;
      }
      final resolved = await _resolvePipUrl(cache: true);
      if (!mounted || resolved.url.isEmpty) {
        if (_autoPipArmed) {
          _autoPipArmed = false;
          await _iosPip.disarmAuto();
        }
        return;
      }
      _autoPipArmed = true;
      await _iosPip.armAuto(
        url: resolved.url,
        headers: resolved.headers,
        positionMs: session.currentPosition * 1000,
        rate: session.speed,
      );
    } finally {
      _autoPipSyncing = false;
    }
  }

  Future<void> _enterMini() async {
    if (defaultTargetPlatform == TargetPlatform.iOS && _iosPip.supported) {
      final session = _session;
      final resolved = await _resolvePipUrl();
      if (resolved.url.isNotEmpty) {
        final ok = await _iosPip.enter(
          url: resolved.url,
          headers: resolved.headers,
          positionMs: session.currentPosition * 1000,
          rate: session.speed,
          aspectRatio: session.aspectRatio,
        );
        if (ok) {
          _closeRoutesAbove();
          _session.setLocked(false);
          // 暂停本地播放器移到 _iosPipState(active=true) 回调：只有系统 PiP
          // 真正启动后才暂停，避免 PiP 未启动时点击画中画却把视频暂停。
          return;
        }
      }
    }
    _closeRoutesAbove();
    _session.setLocked(false);
    await _pip.enter(_session.aspectRatio, frame: widget.store.miniWindow);
  }

  Future<void> _restore() async {
    final frame = await _pip.exit();
    if (frame != null) {
      unawaited(widget.store.setMiniWindow(frame).catchError((Object _) {}));
    }
  }

  Future<void> _close() async {
    await _restore();
    if (mounted) Navigator.pop(context);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final size = MediaQuery.sizeOf(context);
    final form = AppScope.formFactorOf(context);
    if (!desktopPlatform ||
        form != FormFactor.window && form != FormFactor.pad ||
        _padFullscreen.value ||
        _windowFullscreen ||
        size.width > size.height ||
        key != LogicalKeyboardKey.f11 &&
            key != LogicalKeyboardKey.enter &&
            key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _padFullscreen.value = true;
    return KeyEventResult.handled;
  }

  void _padFullscreenChanged() {
    _applyPadFullscreen(_padFullscreen.value);
    setState(() {});
  }

  void _applyPadFullscreen(bool full) {
    if (desktopPlatform) {
      unawaited(setWindowFullScreen(full));
      return;
    }
    unawaited(
      AppDevice.setPlayerOrientation(
        full ? PlayerOrientation.lockedLandscape : PlayerOrientation.auto,
      ),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = MediaQuery.of(context);
    final shown = _pip.shown || _pip.leaving && live.size != _media?.size;
    if (!shown || _media == null) _media = live;
    return Stack(
      fit: StackFit.expand,
      children: [
        FocusScope(
          node: _pageScope,
          autofocus: true,
          onKeyEvent: _key,
          child: Offstage(
            offstage: shown,
            child: MediaQuery(
              data: _media!,
              child: Builder(builder: _page),
            ),
          ),
        ),
        if (shown)
          _pip.window
              ? MiniWindowView(
                  handle: widget.handle,
                  onRestore: () => unawaited(_restore()),
                  onClose: () => unawaited(_close()),
                )
              : PictureInPictureView(handle: widget.handle),
        VolumeHudOverlay(hud: VolumeKeysHud.instance),
      ],
    );
  }

  Widget _page(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final pipAvailable = _pip.available ||
        (defaultTargetPlatform == TargetPlatform.iOS && _iosPip.supported);
    final mini = pipAvailable ? () => unawaited(_enterMini()) : null;
    if (_audio && form != FormFactor.television) {
      return AudioPlayerPage(
        store: widget.store,
        handle: widget.handle,
        onMiniWindow: mini,
      );
    }
    if (desktopPlatform) {
      final size = MediaQuery.sizeOf(context);
      return switch (form) {
        FormFactor.phone
            when _wideVideo &&
                !widget.store.playbackPreferences.portraitStyleForWide =>
          LandscapePlayerPage(
            store: widget.store,
            handle: widget.handle,
            onMiniWindow: mini,
          ),
        FormFactor.phone => PortraitPlayerPage(
          store: widget.store,
          handle: widget.handle,
          onMiniWindow: mini,
        ),
        FormFactor.pad => _padPage(context, mini),
        FormFactor.window
            when !_windowFullscreen &&
                (_padFullscreen.value || size.width <= size.height) =>
          _padPage(context, mini),
        FormFactor.window => PlayerPage(
          store: widget.store,
          handle: widget.handle,
          onWindowFullscreen: (value) => _windowFullscreen = value,
          onMiniWindow: mini,
        ),
        FormFactor.television => TelevisionPlayerPage(handle: widget.handle),
      };
    }
    final portraitStyle = widget.store.playbackPreferences.portraitStyleForWide;
    return switch (form) {
      FormFactor.pad || FormFactor.window => _padPage(context, mini),
      FormFactor.phone
          when _wideVideo &&
              !(portraitStyle &&
                  MediaQuery.orientationOf(context) == Orientation.portrait) =>
        LandscapePlayerPage(
          store: widget.store,
          handle: widget.handle,
          followSensor: !portraitStyle,
          onMiniWindow: mini,
        ),
      FormFactor.phone => PortraitPlayerPage(
        store: widget.store,
        handle: widget.handle,
        onFullscreen: _wideVideo
            ? () => unawaited(
                AppDevice.setPlayerOrientation(PlayerOrientation.landscape),
              )
            : null,
        onMiniWindow: mini,
      ),
      FormFactor.television => TelevisionPlayerPage(handle: widget.handle),
    };
  }

  Widget _padPage(BuildContext context, VoidCallback? mini) {
    final size = MediaQuery.sizeOf(context);
    if (_padFullscreen.value || size.width > size.height) {
      return PlayerPage(
        store: widget.store,
        handle: widget.handle,
        padFullscreen: _padFullscreen,
        onMiniWindow: mini,
      );
    }
    final portraitStyle = widget.store.playbackPreferences.portraitStyleForWide;
    return _wideVideo && !portraitStyle
        ? LandscapePlayerPage(
            store: widget.store,
            handle: widget.handle,
            onFullscreen: () => _padFullscreen.value = true,
            onMiniWindow: mini,
          )
        : PortraitPlayerPage(
            store: widget.store,
            handle: widget.handle,
            onFullscreen: _wideVideo ? () => _padFullscreen.value = true : null,
            onMiniWindow: mini,
          );
  }
}
