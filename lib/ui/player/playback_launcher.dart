import 'dart:async';

import 'package:flutter/material.dart';

import '../../follow_state.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import 'playback_handle.dart';
import 'playback_page.dart';

/// 统一的剧集打开入口。
///
/// 当「点开剧集直接播放」开启时，异步拉取详情后直接进入播放器并从上次进度续播，
/// 选集仍保留在播放器内；关闭时回退为先进入详情页。电视端始终走详情页。
Future<void> openDrama(
  BuildContext context, {
  required LocalStore store,
  required Drama drama,
  bool autoplay = false,
}) async {
  final direct = !AppScope.of(context).television &&
      store.playbackPreferences.directPlay;
  if (!direct) {
    await openPage<void>(
      context,
      (_) => DetailPage(store: store, drama: drama, autoplay: autoplay),
    );
    return;
  }
  await openPage<void>(
    context,
    (_) => _DirectPlayGate(store: store, drama: drama, autoplay: autoplay),
  );
}

double _startAt(List<Episode> episodes, int index, WatchEntry? watch) =>
    watch != null && watch.episode == episodes[index].number && !watch.finished
        ? watch.position
        : 0.0;

/// 透明占位页：拉取详情期间显示进度圈，随后原地替换为播放器。
/// 失败则替换为详情页，保证入口始终可用。
class _DirectPlayGate extends StatefulWidget {
  const _DirectPlayGate({
    required this.store,
    required this.drama,
    required this.autoplay,
  });

  final LocalStore store;
  final Drama drama;
  final bool autoplay;

  @override
  State<_DirectPlayGate> createState() => _DirectPlayGateState();
}

class _DirectPlayGateState extends State<_DirectPlayGate> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    unawaited(_launch());
  }

  Future<void> _launch() async {
    final scope = AppScope.of(context);
    final store = widget.store;
    try {
      final detail = await scope.repository.detail(widget.drama);
      if (!mounted || _started) return;
      if (detail.episodes.isEmpty) throw StateError('暂无可播放的分集');
      final watch = store.watched(detail.drama.id);
      final index = resumeEpisodeIndex(detail.episodes, watch);
      final position = _startAt(detail.episodes, index, watch);
      final handle = PlaybackHandle(
        repository: scope.repository,
        store: store,
        detail: detail,
        index: index,
        position: position,
        autoplay: true,
        preopen: store.playbackPreferences.preopens(television: false),
      );
      _started = true;
      await _replace(
        PlaybackPage(store: store, handle: handle),
      );
    } catch (_) {
      if (!mounted || _started) return;
      _started = true;
      await _replace(
        DetailPage(store: store, drama: widget.drama, autoplay: widget.autoplay),
      );
    }
  }

  Future<void> _replace(Widget page) async {
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: CircularProgressIndicator()),
  );
}
