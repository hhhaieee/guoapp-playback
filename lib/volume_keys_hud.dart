import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 实体音量键监听（仅 iOS）。原生监听 AVAudioSession.outputVolume 变化，
/// 通过 MethodChannel 回传，播放器据此显示音量图标 HUD。
class VolumeKeysHud extends ChangeNotifier {
  VolumeKeysHud._() {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    _channel.setMethodCallHandler(_handle);
  }

  static final instance = VolumeKeysHud._();

  static const _channel = MethodChannel('duanju/volume');

  bool _enabled = true;
  bool _visible = false;
  double _volume = 0;
  Timer? _hideTimer;
  int _suppressDepth = 0;

  bool get supported => defaultTargetPlatform == TargetPlatform.iOS;
  bool get enabled => _enabled;
  bool get visible => _visible;
  double get volume => _volume;

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method == 'changed' && _enabled && _suppressDepth == 0) {
      final args = call.arguments as Map? ?? const {};
      final value = (args['volume'] as num?)?.toDouble();
      if (value != null) show(value);
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (!value) hide();
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': value});
    } catch (_) {}
  }

  /// App 自身调整音量时短暂屏蔽 HUD，避免与手势提示重复。
  void beginSuppressed() {
    _suppressDepth++;
    if (_suppressDepth == 1) {
      unawaited(
        _channel.invokeMethod<void>('beginSuppressed').catchError((Object _) {}),
      );
    }
  }

  void endSuppressed() {
    if (_suppressDepth == 0) return;
    _suppressDepth--;
    if (_suppressDepth == 0) {
      unawaited(
        _channel.invokeMethod<void>('endSuppressed').catchError((Object _) {}),
      );
    }
  }

  void show(double value) {
    _volume = value.clamp(0.0, 1.0);
    _visible = true;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1100), hide);
    notifyListeners();
  }

  void hide() {
    _hideTimer?.cancel();
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }
}

/// 音量提示浮层：深色圆角胶囊 + 扬声器图标 + 横向音量条（仿系统小图标）。
/// 音量 0 显示静音图标；音量最大/最小同样显示。
class VolumeHudOverlay extends StatelessWidget {
  const VolumeHudOverlay({super.key, required this.hud});

  final VolumeKeysHud hud;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: hud,
    builder: (context, _) {
      if (!hud.visible) return const SizedBox.shrink();
      final level = hud.volume;
      final muted = level <= 0.001;
      return IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -0.4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .72),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  muted
                      ? Icons.volume_off_rounded
                      : level >= 0.999
                      ? Icons.volume_up_rounded
                      : Icons.volume_down_rounded,
                  color: Colors.white,
                  size: 22,
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 120,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: level,
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: .25),
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
