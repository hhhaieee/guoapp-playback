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
  void Function(bool active, {String? error})? onState;
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
      case 'state':
        final args = call.arguments as Map? ?? const {};
        final active = args['active'] == true;
        _active = active;
        onState?.call(active, error: args['error'] as String?);
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
