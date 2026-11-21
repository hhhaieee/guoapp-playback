import 'package:flutter/services.dart';

/// 系统生物识别（Face ID / Touch ID）认证，带设备锁屏密码兜底。
/// 通过原生 MethodChannel 调用，不引入额外依赖。
class BiometricAuth {
  BiometricAuth._();

  static const _channel = MethodChannel('duanju/biometric');

  /// 是否支持生物识别或设备密码。两者都没有（模拟器 / 无密码）时返回 false。
  static Future<bool> supported() async {
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 弹出系统身份验证。通过返回 true；取消 / 失败返回 false。
  /// 设备不支持生物识别且无密码时，原生端直接放行返回 true。
  static Future<bool> authenticate(String reason) async {
    try {
      return await _channel.invokeMethod<bool>('authenticate', {
        'reason': reason,
      }) ?? false;
    } catch (_) {
      return false;
    }
  }
}
