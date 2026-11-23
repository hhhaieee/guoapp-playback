import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_color.dart';

class AppLauncherIcon {
  const AppLauncherIcon._();
  static const _channel = MethodChannel('duanju/device');
  static const _key = 'launcherIcon';
  static String? _requested;

  static Future<void> sync(ThemeColor? color) async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    final name = color == null || color == ThemeColor.star
        ? 'star'
        : color.name;
    // 未正式切入原生方法前不写偏好，避免旧包失败记录阻塞升级后的重试。
    if (_requested == name) return;
    _requested = name;
    try {
      await _channel.invokeMethod<void>('setLauncherIcon', {'name': name});
    } on MissingPluginException {
      return;
    } on PlatformException {
      _requested = null;
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getString(_key) != name) {
      await preferences.setString(_key, name);
    }
  }
}
