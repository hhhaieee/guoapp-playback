import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core_bridge.dart';
import '../../diary_service.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import 'settings_rows.dart';
import '../../diagnostics/source_diagnosis.dart';

/// 我的 › 诊断 › 数据源诊断。逐源串行探测，定位卡在哪一步，支持关闭异常源。
/// 通过 [open] 以子页形式打开（由外层提供 Scaffold/AppBar），本身是纯内容 widget。
class SourceDiagnosisView extends StatefulWidget {
  const SourceDiagnosisView({
    super.key,
    required this.store,
    required this.open,
  });

  final LocalStore store;
  final void Function(String title, WidgetBuilder body) open;

  @override
  State<SourceDiagnosisView> createState() => _SourceDiagnosisViewState();
}

class _SourceDiagnosisViewState extends State<SourceDiagnosisView> {
  final Map<String, DiagnosisResult> _results = {};
  final Set<String> _selected = {};
  /// 被本页关闭、但仍留在列表里以便重新开启的源。
  final Set<String> _hiddenButShown = {};
  bool _running = false;
  bool _copied = false;
  /// 主检测循环（串行）。验证后重测会等它跑完再执行，避免并发卡死。
  Future<void>? _detectTask;
  late SourceDiagnostics _diagnostics;

  AppRepository get _repository => AppScope.of(context).repository;

  /// 诊断对象：当前已开启的片源（顺序跟随首页片源顺序），
  /// 另外并入被本页关闭的源，方便一键重新开启。
  List<SourceSite> get _sources {
    final enabled = widget.store.sources.map((s) => s.id).toSet();
    final out = <SourceSite>[
      for (final site in SourceSite.values)
        if (enabled.contains(site.id) || _hiddenButShown.contains(site.id))
          site,
    ];
    for (final raw in _hiddenButShown) {
      final site = SourceSite.byId(raw);
      if (site.id == raw && site.available && !out.any((s) => s.id == raw)) {
        out.add(site);
      }
    }
    return out;
  }

  List<SourceSite> get _failingSources => _sources.where((site) {
    final result = _results[site.id];
    return result != null && result.done && !result.allOK;
  }).toList();

  @override
  void initState() {
    super.initState();
    final version = AppScope.of(context).version;
    _diagnostics = SourceDiagnostics(_repository, version: version);
    // 默认全选。
    _selected.addAll(_sources.map((s) => s.id));
    DiaryService.add('[诊断] 打开数据源诊断，共 ${_sources.length} 个片源');
  }

  /// 该源当前是否开启（本 App 内置源、插件源、采集站统一走站源开关）。
  bool _sourceOn(SourceSite site) => widget.store.sourceEnabled(site.id);

  /// 核心内置源（红果）恒开不可关。
  bool _canToggle(SourceSite site) => site.id != hongguoSourceId;

  Future<void> _setSource(SourceSite site, {required bool on}) async {
    try {
      await widget.store.setSourceEnabled(site.id, on);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法切换片源：$error')));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      if (on) {
        _hiddenButShown.remove(site.id);
      } else {
        _hiddenButShown.add(site.id);
      }
    });
    DiaryService.add('[诊断] ${on ? '开启' : '关闭'}片源 ${site.name}');
  }

  Future<void> _closeAllFailing() async {
    for (final site in _failingSources) {
      if (_canToggle(site) && _sourceOn(site)) {
        await _setSource(site, on: false);
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已关闭全部异常源')));
    }
  }

  void _run() {
    if (_running) return;
    final targets = _sources.where((s) => _selected.contains(s.id)).toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择要检测的片源')));
      return;
    }
    setState(() => _running = true);
    DiaryService.add('[诊断] 开始主检测，${targets.length} 个片源');
    final task = _detectLoop(targets);
    _detectTask = task;
    task.whenComplete(() {
      if (mounted) setState(() => _running = false);
      DiaryService.add('[诊断] 主检测结束');
    });
  }

  Future<void> _detectLoop(List<SourceSite> targets) async {
    for (final site in targets) {
      if (!mounted) return;
      setState(() {
        _results[site.id] = DiagnosisResult(
          running: true,
          mode: SourceDiagnostics.modeOf(site),
        );
      });
      final result = await _diagnostics.probe(site);
      if (!mounted) return;
      setState(() => _results[site.id] = result);
      DiaryService.add(
        '[诊断] ${site.name} ${result.summary}（${result.mode.label}）',
      );
    }
  }

  /// 验证通过后重测：等待主检测循环结束再执行，防止两个源并发检测卡死。
  void _recheck(SourceSite site) {
    final previous = _detectTask;
    final task = (() async {
      if (previous != null) await previous;
      if (!mounted) return;
      setState(() {
        _results[site.id] = DiagnosisResult(
          running: true,
          mode: SourceDiagnostics.modeOf(site),
        );
      });
      final result = await _diagnostics.probe(site);
      if (!mounted) return;
      setState(() => _results[site.id] = result);
      DiaryService.add('[诊断] ${site.name} 验证后重测：${result.summary}');
    })();
    _detectTask = task;
  }

  Future<void> _copyReport() async {
    final entries = _sources
        .where((s) => _results[s.id]?.done == true)
        .map((s) => MapEntry(s, _results[s.id]!));
    final text = _diagnostics.report(entries, DateTime.now());
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('诊断报告已复制')));
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _openVerify(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!opened && mounted) {
      await Clipboard.setData(ClipboardData(text: url));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开浏览器，验证链接已复制')),
      );
    }
  }

  // 灰=未检测，主题色=检测中，绿=全通过，橙=有失败。
  Color _dotColor(DiagnosisResult result, ColorScheme colors) {
    if (result.running) return colors.primary;
    if (!result.done) return colors.outline;
    return result.allOK ? Colors.green : Colors.orange;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _header(colors),
          if (_running) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '正在逐个检测，每个源大约需要几秒…',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          for (final site in _sources)
            _sourceCard(site, _results[site.id] ?? DiagnosisResult(), colors),
          const SizedBox(height: 8),
          Text(
            '深度A（核心主站）：会话/设备 → 搜索 → 搜索分页 → 详情 → 播放解析 → '
            '流参数 → 取流吞吐（前 512 KB）→ 榜单。\n'
            '深度B（第二主站）：搜索 → 详情 → 播放解析 → 流参数 → 取流吞吐 → 榜单。\n'
            '标准（其余源）：搜索/列表 → 详情 → 播放解析 → 媒体可达。',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _header(ColorScheme colors) {
    final hasResults = _results.values.any((r) => r.done);
    return SettingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _running ? null : _run,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_running ? '检测中…' : '开始检测'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasResults ? _copyReport : null,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: Text(_copied ? '已复制' : '复制报告'),
                  ),
                  if (!_running && _failingSources.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: _closeAllFailing,
                      icon: const Icon(Icons.block_outlined),
                      label: const Text('关闭异常源'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.error,
                      ),
                    ),
                  if (!_running) ...[
                    TextButton(
                      onPressed: () => setState(
                        () => _selected.addAll(_sources.map((s) => s.id)),
                      ),
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: () => setState(_selected.clear),
                      child: const Text('全不选'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '已选 ${_selected.length}/${_sources.length} 个片源 · 点条目可单选/取消',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              if (!_running && _failingSources.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '发现 ${_failingSources.length} 个异常源，可点「关闭异常源」批量关闭，'
                    '或在下方单独开关',
                    style: TextStyle(fontSize: 12, color: colors.error),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sourceCard(SourceSite site, DiagnosisResult result, ColorScheme colors) {
    final isOn = _selected.contains(site.id);
    final failing = result.done && !result.allOK;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SettingsCard(
        children: [
          Opacity(
            opacity: isOn || _running ? 1 : 0.5,
            child: TileFocus(
              builder: (focusNode) => ListTile(
                focusNode: focusNode,
                onTap: _running
                    ? null
                    : () => setState(() {
                        if (isOn) {
                          _selected.remove(site.id);
                        } else {
                          _selected.add(site.id);
                        }
                      }),
                leading: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _dotColor(result, colors),
                    shape: BoxShape.circle,
                  ),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        site.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      result.summary,
                      style: TextStyle(
                        fontSize: 12,
                        color: result.done
                            ? (result.allOK ? Colors.green : Colors.orange)
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    if (!_running)
                      Icon(
                        isOn
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked,
                        color: isOn ? colors.primary : colors.onSurfaceVariant,
                        size: 20,
                      ),
                  ],
                ),
                subtitle: Text(
                  '${SourceDiagnostics.modeOf(site).label}检测 · '
                  '${site.groupName}',
                  style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                ),
              ),
            ),
          ),
          if (failing && !_running) _sourceToggle(site, colors),
          if (result.steps.isNotEmpty) ...[
            const Divider(indent: 16, endIndent: 16, height: 1),
            for (final step in result.steps) _stepRow(step, colors),
          ],
          if (failing && !_running && result.verifyUrl != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: OutlinedButton.icon(
                onPressed: () => _openVerify(result.verifyUrl!),
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('去验证后重测'),
                style: OutlinedButton.styleFrom(foregroundColor: colors.primary),
              ),
            ),
          if (failing && !_running && result.verifyUrl == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: TextButton.icon(
                onPressed: () => _recheck(site),
                icon: const Icon(Icons.refresh),
                label: const Text('重新检测该源'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sourceToggle(SourceSite site, ColorScheme colors) {
    final on = _sourceOn(site);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: _canToggle(site)
          ? SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                on ? '已开启 · 点此关闭该源' : '已关闭 · 点此重新开启',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              value: on,
              onChanged: (value) => _setSource(site, on: value),
            )
          : Row(
              children: [
                const Icon(Icons.lock_outline, size: 14),
                const SizedBox(width: 6),
                Text(
                  '核心内置源，不可关闭',
                  style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ],
            ),
    );
  }

  Widget _stepRow(DiagnosisStep step, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            step.ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
            size: 16,
            color: step.ok ? Colors.green : colors.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        step.name,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${step.ms}ms',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  step.info,
                  style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
