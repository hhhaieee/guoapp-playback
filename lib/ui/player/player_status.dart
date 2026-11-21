import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../playback_session.dart';

String formatNetworkSpeed(int bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024).round()} KB/s';
}

class NetworkSpeedText extends StatefulWidget {
  const NetworkSpeedText({super.key, required this.session, this.style});
  final PlaybackSession session;
  final TextStyle? style;

  @override
  State<NetworkSpeedText> createState() => _NetworkSpeedTextState();
}

class _NetworkSpeedTextState extends State<NetworkSpeedText> {
  Timer? _timer;
  int? _speed;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final speed = await widget.session.networkSpeed();
    if (mounted && speed != _speed) setState(() => _speed = speed);
  }

  @override
  Widget build(BuildContext context) {
    final speed = _speed;
    if (speed == null) return const SizedBox.shrink();
    return Text(formatNetworkSpeed(speed), style: widget.style);
  }
}

/// 视频技术信息：分辨率 + 像素格式（近似编码信息），随 videoParams 流更新。
class VideoTechText extends StatefulWidget {
  const VideoTechText({super.key, required this.player, this.style});
  final Player player;
  final TextStyle? style;

  @override
  State<VideoTechText> createState() => _VideoTechTextState();
}

class _VideoTechTextState extends State<VideoTechText> {
  StreamSubscription<VideoParams>? _subscription;
  VideoParams? _params;

  @override
  void initState() {
    super.initState();
    _params = widget.player.state.videoParams;
    _subscription = widget.player.stream.videoParams.listen((params) {
      if (mounted) setState(() => _params = params);
    });
  }

  @override
  void didUpdateWidget(covariant VideoTechText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _subscription?.cancel();
      _params = widget.player.state.videoParams;
      _subscription = widget.player.stream.videoParams.listen((params) {
        if (mounted) setState(() => _params = params);
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _params;
    if (p == null) return const SizedBox.shrink();
    final w = (p.dw ?? p.w) ?? 0;
    final h = (p.dh ?? p.h) ?? 0;
    final buffer = <String>[];
    if (w > 0 && h > 0) buffer.add('${w}×${h}');
    final fmt = p.pixelformat;
    if (fmt != null && fmt.isNotEmpty) buffer.add(fmt);
    if (buffer.isEmpty) return const SizedBox.shrink();
    return Text(buffer.join(' · '), style: widget.style);
  }
}

class ClockText extends StatefulWidget {
  const ClockText({super.key, this.style});
  final TextStyle? style;

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      final now = DateTime.now();
      if (now.minute != _now.minute) setState(() => _now = now);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int value) => value.toString().padLeft(2, '0');
    return Text('${two(_now.hour)}:${two(_now.minute)}', style: widget.style);
  }
}
