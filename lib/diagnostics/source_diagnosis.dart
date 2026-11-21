import 'dart:async';
import 'dart:io';

import '../core_bridge.dart';
import '../models.dart';
import '../ranking_models.dart';

/// 「数据源诊断」数据层：只调用 App 已有的片源能力并计时，不实现取流逻辑。
/// 设计对齐黑果夜剧的同名功能，但适配本项目的数据驱动片源模型。

/// 错误分类：区分上游错误 / 参数错误 / 暂不支持，供 UI 展示与报告使用。
enum DiagnosisErrorKind { upstream, parameter, unsupported }

extension DiagnosisErrorKindLabel on DiagnosisErrorKind {
  String get label => switch (this) {
    DiagnosisErrorKind.upstream => '上游错误',
    DiagnosisErrorKind.parameter => '参数错误',
    DiagnosisErrorKind.unsupported => '暂不支持',
  };
}

/// 诊断过程中抛出的、带分类与可选验证链接的错误。
class DiagnosisFailure implements Exception {
  DiagnosisFailure(
    this.message, {
    this.kind = DiagnosisErrorKind.upstream,
    this.verifyUrl,
  });
  final String message;
  final DiagnosisErrorKind kind;
  final String? verifyUrl;
  @override
  String toString() => message;
}

/// 探测模式：核心主站深度A、第二主站深度B、其余标准。
enum DiagnosisMode { deepA, deepB, standard }

extension DiagnosisModeLabel on DiagnosisMode {
  String get label => switch (this) {
    DiagnosisMode.deepA => '深度A',
    DiagnosisMode.deepB => '深度B',
    DiagnosisMode.standard => '标准',
  };
}

/// 单个探测步骤的结果。
class DiagnosisStep {
  const DiagnosisStep({
    required this.name,
    required this.ok,
    required this.ms,
    required this.info,
    this.kind,
    this.verifyUrl,
  });
  final String name;
  final bool ok;
  final int ms;
  final String info;
  final DiagnosisErrorKind? kind;
  final String? verifyUrl;

  String get glyph => ok ? '✓' : '✗';
}

/// 单个片源的诊断结果。
class DiagnosisResult {
  DiagnosisResult({
    this.steps = const [],
    this.running = false,
    this.done = false,
    this.mode = DiagnosisMode.standard,
  });
  final List<DiagnosisStep> steps;
  final bool running;
  final bool done;
  final DiagnosisMode mode;

  bool get allOK => done && steps.isNotEmpty && steps.every((s) => s.ok);
  int get totalMs => steps.fold(0, (sum, s) => sum + s.ms);
  int get passed => steps.where((s) => s.ok).length;

  String get summary {
    if (running) return '检测中…';
    if (!done) return '未检测';
    return allOK
        ? '全部通过 · ${totalMs}ms'
        : '$passed/${steps.length} 通过';
  }

  String? get verifyUrl {
    for (final step in steps) {
      if (!step.ok && step.verifyUrl != null) return step.verifyUrl;
    }
    return null;
  }
}

/// 设备注册时间记录，用于判断会话是否可能过期（超过 7 分钟）。
class DeviceClock {
  static final Map<String, DateTime> _registered = {};

  static void mark(String source) => _registered[source] = DateTime.now();

  static bool stale(String source) {
    final at = _registered[source];
    if (at == null) return false;
    return DateTime.now().difference(at) > const Duration(minutes: 7);
  }

  static String describe(String source, bool registered) {
    final at = _registered[source];
    if (!registered) return '未注册设备（首次使用会现场注册）';
    if (at == null) return '设备已就绪 · 注册时间未知';
    final age = DateTime.now().difference(at).inSeconds;
    final ageText = age > 3600
        ? '${age ~/ 3600} 小时前'
        : age > 60
        ? '${age ~/ 60} 分钟前'
        : '$age 秒前';
    return '设备已就绪 · 注册于$ageText'
        + (stale(source) ? ' · ⚠️ 超过 7 分钟，取流可能被软拒' : ' · 会话新鲜');
  }
}

/// 诊断探测器：注入 [AppRepository]，串行执行，全程只读不改动片源能力。
class SourceDiagnostics {
  SourceDiagnostics(this.repository, {this.version = ''});

  final AppRepository repository;
  final String version;
  static const int _throughputBytes = 512 * 1024;
  static const Duration _timeout = Duration(seconds: 15);

  /// 判断源采用的探测模式。核心主站=深度A，第二主站=深度B，其余=标准。
  static DiagnosisMode modeOf(SourceSite site) {
    if (site.id == hongguoSourceId) return DiagnosisMode.deepA;
    if (site.id == 'huangguo' || site.id == 'huangdou') {
      return DiagnosisMode.deepB;
    }
    return DiagnosisMode.standard;
  }

  /// 把任意异常归一化成带分类的诊断错误。
  static DiagnosisFailure normalize(Object error) {
    if (error is DiagnosisFailure) return error;
    if (error is AppFailure) {
      final code = error.code;
      final message = error.message;
      // 人机验证 / Cloudflare 拦截：附验证链接（本项目无独立验证页，链接指向片源官网首页）。
      if (code == 'source_blocked' ||
          code == 'source_login' ||
          message.contains('人机') ||
          message.contains('验证') ||
          message.contains('Cloudflare') ||
          message.contains('captcha')) {
        return DiagnosisFailure(
          message,
          kind: DiagnosisErrorKind.upstream,
          verifyUrl: _verifyUrlFor(message),
        );
      }
      if (message.contains('不支持') ||
          message.contains('暂未') ||
          code == 'unsupported') {
        return DiagnosisFailure(message, kind: DiagnosisErrorKind.unsupported);
      }
      if (message.contains('参数') ||
          message.contains('无效') ||
          message.contains('必填') ||
          code == 'parameter') {
        return DiagnosisFailure(message, kind: DiagnosisErrorKind.parameter);
      }
      return DiagnosisFailure(message, kind: DiagnosisErrorKind.upstream);
    }
    final text = error.toString();
    if (text.contains('SocketException') ||
        text.contains('TimeoutException') ||
        text.contains('HandshakeException') ||
        text.contains('ClientException')) {
      return DiagnosisFailure(text, kind: DiagnosisErrorKind.upstream);
    }
    return DiagnosisFailure(text, kind: DiagnosisErrorKind.parameter);
  }

  /// 从错误信息里尽量解析出可打开的验证链接；解析不到返回 null。
  static String? _verifyUrlFor(String message) {
    final match = RegExp(r'https?://[^\s，。、]+').firstMatch(message);
    return match?.group(0);
  }

  /// 计时执行一步，成功/失败都产出 [DiagnosisStep]。
  static Future<DiagnosisStep> timed(
    String name,
    Future<String> Function() operation,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final info = await operation();
      sw.stop();
      return DiagnosisStep(
        name: name,
        ok: true,
        ms: sw.elapsedMilliseconds,
        info: info,
      );
    } catch (error) {
      sw.stop();
      final failure = normalize(error);
      return DiagnosisStep(
        name: name,
        ok: false,
        ms: sw.elapsedMilliseconds,
        info: '${failure.kind.label}：${failure.message}',
        kind: failure.kind,
        verifyUrl: failure.verifyUrl,
      );
    }
  }

  /// 对单个源执行完整探测；上一步拿不到数据时提前结束该源。
  Future<DiagnosisResult> probe(SourceSite site) async {
    final mode = modeOf(site);
    switch (mode) {
      case DiagnosisMode.deepA:
        return _probeDeep(site, mode, withSessionAndPaging: true);
      case DiagnosisMode.deepB:
        return _probeDeep(site, mode, withSessionAndPaging: false);
      case DiagnosisMode.standard:
        return _probeStandard(site);
    }
  }

  /// 搜索：返回首页结果。search 失败时按 standard 约定会终止。
  Future<CatalogPage> _search(SourceSite site) => repository.catalog(
    site.id,
    query: '爱情',
    page: 1,
    force: true,
  );

  /// 详情 + 取首集，返回 null 时调用方提前结束。
  Future<DramaDetail?> _detail(Drama first) async {
    try {
      return await repository.detail(first);
    } catch (_) {
      rethrow;
    }
  }

  /// 深度探测（核心主站 A / 第二主站 B）。
  /// A 比 B 多「会话/设备」「搜索分页」两步。
  Future<DiagnosisResult> _probeDeep(
    SourceSite site,
    DiagnosisMode mode, {
    required bool withSessionAndPaging,
  }) async {
    final steps = <DiagnosisStep>[];

    if (withSessionAndPaging) {
      steps.add(
        await timed('会话 / 设备', () async {
          final registered = site.devices
              ? await repository.sourceDevices(site.id)
              : true;
          if (registered) DeviceClock.mark(site.id);
          return DeviceClock.describe(site.id, registered);
        }),
      );
    }

    CatalogPage? page;
    Drama? first;
    steps.add(
      await timed('搜索', () async {
        page = await _search(site);
        first = page!.items.isEmpty ? null : page!.items.first;
        if (first == null) throw DiagnosisFailure('返回 0 条结果');
        return '${page!.items.length} 条' + (page!.hasMore ? ' · 有下一页' : '');
      }),
    );
    if (first == null) {
      return DiagnosisResult(steps: steps, done: true, mode: mode);
    }

    if (withSessionAndPaging) {
      steps.add(
        await timed('搜索分页', () async {
          if (!(page?.hasMore ?? false)) return '单页结果，跳过';
          final next = await repository.catalog(
            site.id,
            query: '爱情',
            page: 2,
            force: true,
          );
          return '第 2 页 ${next.items.length} 条'
              + (next.hasMore ? ' · 仍有更多' : '');
        }),
      );
    }

    DramaDetail? detail;
    steps.add(
      await timed('剧集详情', () async {
        detail = await _detail(first!);
        if (detail!.episodes.isEmpty) {
          throw DiagnosisFailure('没有分集');
        }
        return '《${detail!.drama.title}》· ${detail!.episodes.length} 集';
      }),
    );
    if (detail == null || detail!.episodes.isEmpty) {
      return DiagnosisResult(steps: steps, done: true, mode: mode);
    }

    final episode = detail!.episodes.first;
    PlaybackPlan? plan;
    steps.add(
      await timed('播放解析', () async {
        plan = await repository.resolve(first!, episode);
        if (plan!.url.isEmpty) throw DiagnosisFailure('解析结果没有可用流地址');
        final encrypted = plan!.decryptionKey.isNotEmpty;
        final routes = plan!.routeCount > 1 ? ' · ${plan!.routeCount} 条线路' : '';
        return '1 条流 · ${plan!.qualities.length} 档画质'
            ' · ${encrypted ? '加密' : '明文'}$routes';
      }),
    );
    if (plan == null || plan!.url.isEmpty) {
      return DiagnosisResult(steps: steps, done: true, mode: mode);
    }

    steps.add(
      await timed('流参数', () async {
        final parts = <String>[];
        parts.add(plan!.url.isEmpty ? '地址为空' : plan!.url);
        if (plan!.qualities.isNotEmpty) {
          parts.add('画质档 ${plan!.qualities.join('/')}');
        }
        parts.add(plan!.decryptionKey.isEmpty ? '未加密' : '加密');
        parts.add('线路 ${plan!.routeIndex + 1}/${plan!.routeCount}');
        if (DeviceClock.stale(site.id)) parts.add('⚠️ 会话可能过期');
        return parts.join(' · ');
      }),
    );

    steps.add(
      await timed('取流吞吐（前 512 KB）', () async {
        return measureThroughput(plan!);
      }),
    );

    steps.add(
      await timed('榜单', () async {
        final boards = await repository.rankingBoards();
        final own = boards.where((b) => b.source == site.id).toList();
        if (own.isEmpty) throw DiagnosisFailure('该源没有可用榜单');
        final ranking = await repository.rankings(own.first);
        return '${own.first.name} ${ranking.items.length} 条';
      }),
    );

    return DiagnosisResult(steps: steps, done: true, mode: mode);
  }

  /// 标准探测：搜索/列表 → 详情 → 播放解析 → 媒体可达。
  Future<DiagnosisResult> _probeStandard(SourceSite site) async {
    final steps = <DiagnosisStep>[];
    Drama? first;
    steps.add(
      await timed('搜索 / 列表', () async {
        final page = await repository.catalog(
          site.id,
          query: 'a',
          page: 1,
          force: true,
        );
        first = page.items.isEmpty ? null : page.items.first;
        if (first == null) {
          // 搜索无结果时退化为分类列表，尽量拿到一个可探测的剧。
          final categories = await repository.categories(site.id);
          for (final category in categories.take(3)) {
            final list = await repository.catalog(
              site.id,
              category: category.id,
              page: 1,
              force: true,
            );
            if (list.items.isNotEmpty) {
              first = list.items.first;
              return '${category.name} 返回 ${list.items.length} 条';
            }
          }
          throw DiagnosisFailure('搜索与分类列表均返回 0 条');
        }
        return '${page.items.length} 条';
      }),
    );
    if (first == null) {
      return DiagnosisResult(steps: steps, done: true);
    }

    DramaDetail? detail;
    steps.add(
      await timed('详情', () async {
        detail = await _detail(first!);
        if (detail!.episodes.isEmpty) throw DiagnosisFailure('没有分集');
        return '《${detail!.drama.title}》共 ${detail!.episodes.length} 集';
      }),
    );
    if (detail == null || detail!.episodes.isEmpty) {
      return DiagnosisResult(steps: steps, done: true);
    }

    PlaybackPlan? plan;
    steps.add(
      await timed('播放解析', () async {
        plan = await repository.resolve(first!, detail!.episodes.first);
        if (plan!.url.isEmpty) throw DiagnosisFailure('没有可用流');
        return '1 条流 · ${plan!.qualities.length} 档画质'
            ' · ${plan!.decryptionKey.isEmpty ? '明文' : '加密'}';
      }),
    );
    if (plan == null || plan!.url.isEmpty) {
      return DiagnosisResult(steps: steps, done: true);
    }

    steps.add(
      await timed('媒体可达', () async {
        return checkReachable(plan!);
      }),
    );

    return DiagnosisResult(steps: steps, done: true);
  }

  /// 取流吞吐：Range 只读前 512KB 即断开，输出 HTTP状态·KB·首字节ms·Mbps。
  Future<String> measureThroughput(PlaybackPlan plan) async {
    final uri = Uri.tryParse(plan.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw DiagnosisFailure('流地址无效');
    }
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = _timeout;
    int firstByteMs = -1;
    int received = 0;
    int status = 0;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set('Range', 'bytes=0-${_throughputBytes - 1}');
      plan.headers.forEach((key, value) {
        if (key.toLowerCase() == 'range') return;
        try {
          request.headers.set(key, value);
        } catch (_) {}
      });
      final response = await request.close().timeout(_timeout);
      status = response.statusCode;
      if (status < 200 || status >= 400) {
        throw DiagnosisFailure('HTTP $status', kind: DiagnosisErrorKind.upstream);
      }
      await for (final chunk in response.timeout(_timeout)) {
        if (firstByteMs < 0) firstByteMs = sw.elapsedMilliseconds;
        received += chunk.length;
        if (received >= _throughputBytes) break;
      }
    } on TimeoutException {
      throw DiagnosisFailure('取流超时（15 秒）');
    } on SocketException catch (error) {
      throw DiagnosisFailure('连接失败：${error.message}');
    } finally {
      client.close(force: true);
    }
    sw.stop();
    if (received <= 0) throw DiagnosisFailure('连接成功但没有数据');
    final seconds = (sw.elapsedMicroseconds > 0 ? sw.elapsedMicroseconds : 1) /
        1_000_000;
    final mbps = received * 8 / seconds / 1_000_000;
    return 'HTTP $status · ${(received / 1024).toStringAsFixed(0)} KB'
        ' · 首字节 ${firstByteMs < 0 ? 0 : firstByteMs} ms'
        ' · ${mbps.toStringAsFixed(1)} Mbps';
  }

  /// 媒体可达：只读少量字节，要求 HTTP 200-399。
  Future<String> checkReachable(PlaybackPlan plan) async {
    final uri = Uri.tryParse(plan.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw DiagnosisFailure('媒体地址无效');
    }
    final client = HttpClient()..connectionTimeout = _timeout;
    int status = 0;
    int received = 0;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      plan.headers.forEach((key, value) {
        try {
          request.headers.set(key, value);
        } catch (_) {}
      });
      final response = await request.close().timeout(_timeout);
      status = response.statusCode;
      if (status < 200 || status >= 400) {
        throw DiagnosisFailure('HTTP $status', kind: DiagnosisErrorKind.upstream);
      }
      await for (final chunk in response.timeout(_timeout)) {
        received += chunk.length;
        if (received >= 4096) break;
      }
    } on TimeoutException {
      throw DiagnosisFailure('连接超时（15 秒）');
    } on SocketException catch (error) {
      throw DiagnosisFailure('连接失败：${error.message}');
    } finally {
      client.close(force: true);
    }
    return 'HTTP $status · 响应 $received 字节';
  }

  /// 生成纯文本报告。
  String report(
    Iterable<MapEntry<SourceSite, DiagnosisResult>> entries,
    DateTime time,
  ) {
    final lines = <String>[
      '数据源诊断报告 · $version',
      '时间：${time.toString().substring(0, 19)}',
      '',
    ];
    for (final entry in entries) {
      final result = entry.value;
      if (!result.done) continue;
      lines.add('【${entry.key.name}】${result.summary}');
      for (final step in result.steps) {
        lines.add(
          '  ${step.glyph} ${step.name} ${step.ms}ms · ${step.info}',
        );
      }
      lines.add('');
    }
    return lines.join('\n');
  }
}
