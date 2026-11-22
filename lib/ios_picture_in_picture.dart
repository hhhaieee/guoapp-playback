import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS 系统画中画桥接：用独立 AVPlayer 播放 media_kit 的本地代理地址。
/// 仅在 iOS 15+ 且系统支持时可用；其它平台一律不可用。
class IosPictureInPicture extends ChangeNotifier {
  IosPictureInPicture._() {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    _channel.setMethodCallHandler(_handle);
    unawaited(_status());
  }

  static final instance = IosPictureInPicture._();

  static const _channel = MethodChannel('duanju/pip');

  void Function(String action)? onAction;
  void Function(bool active, {String? error, double? positionMs, bool? playing})? onState;
  void Function(String message)? onDiag;
  bool _supported = false;
  bool _active = false;

  bool get supported => defaultTargetPlatform == TargetPlatform.iOS && _supported;
  bool get active => _active;

  Future<void> _status() async {
    try {
      _supported = await _channel.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      _supported = false;
    }
    notifyListeners();
  }

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'diag':
        onDiag?.call(call.arguments as String? ?? '');
      case 'state':
        final args = call.arguments as Map? ?? const {};
        final active = args['active'] == true;
        _active = active;
        final positionMs = (args['positionMs'] as num?)?.toDouble();
        final playing = args['playing'] as bool?;
        onState?.call(
          active,
          error: args['error'] as String?,
          positionMs: positionMs,
          playing: playing,
        );
        if (!active) onAction?.call('stopped');
    }
  }

  /// 进入画中画。[url] 为 Go 核心本地代理地址，已包含鉴权与解密。
  Future<bool> enter({
    required String url,
    required Map<String, String> headers,
    required double positionMs,
    required double rate,
    required double aspectRatio,
  }) async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('enter', {
        'url': url,
        'headers': headers,
        'positionMs': positionMs,
        'rate': rate,
        'width': (1000 * (aspectRatio >= 1 ? aspectRatio : 1)).round(),
        'height': (1000 / (aspectRatio >= 1 ? aspectRatio : 1 / aspectRatio)).round(),
      }) ?? false;
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> exit() async {
    try {
      await _channel.invokeMethod<void>('exit');
    } catch (_) {}
  }

  /// 「离开应用时自动画中画」：把当前播放参数告知原生，App 进入后台时由
  /// 原生在 willResignActive 时机自动启动系统画中画。
  Future<void> armAuto({
    required String url,
    required Map<String, String> headers,
    required double positionMs,
    required double rate,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('armAuto', {
        'url': url,
        'headers': headers,
        'positionMs': positionMs,
        'rate': rate,
      });
    } catch (_) {}
  }

  Future<void> disarmAuto() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('disarmAuto');
    } catch (_) {}
  }

  /// 画中画播放中切集：用新一集的流地址替换当前 item，PiP 窗口不中断。
  Future<void> switchSource({
    required String url,
    required Map<String, String> headers,
    required double positionMs,
    required double rate,
  }) async {
    if (!supported || !_active) return;
    try {
      await _channel.invokeMethod<void>('switchSource', {
        'url': url,
        'headers': headers,
        'positionMs': positionMs,
        'rate': rate,
      });
    } catch (_) {}
  }

  /// 与 Flutter 播放器同步播放态/进度。
  void update({required bool playing, required double rate, double? positionMs}) {
    if (!supported || !_active) return;
    unawaited(
      _channel.invokeMethod<void>('update', {
        'playing': playing,
        'rate': rate,
        'seek': positionMs != null,
        'positionMs': positionMs,
      }).catchError((Object _) {}),
    );
  }
}
