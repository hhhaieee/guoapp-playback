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
    if (_requested == name) return;
    _requested = name;
    final preferences = await SharedPreferences.getInstance();
    if (await preferences.getString(_key) == name) return;
    try {
      await _channel.invokeMethod<void>('setLauncherIcon', {'name': name});
    } on MissingPluginException {
      return;
    } on PlatformException {
      _requested = null;
      return;
    }
    await preferences.setString(_key, name);
  }
}
