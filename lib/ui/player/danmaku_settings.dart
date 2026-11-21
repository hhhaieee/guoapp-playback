import 'package:flutter/material.dart';

import '../../catalog_sort.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/slider_tile.dart';

const _colorLabels = ['白色', '黄色', '青色', '粉色', '绿色'];

class DanmakuSettings extends StatelessWidget {
  const DanmakuSettings({
    super.key,
    this.session,
    this.preferences,
    this.save,
    this.onFailure,
    this.dense = false,
  }) : assert(
         session != null || (preferences != null && save != null),
         '需要 session，或者 preferences 与 save',
       );

  final PlaybackSession? session;
  final PlaybackPreferences? preferences;
  final ValueChanged<PlaybackPreferences>? save;
  final VoidCallback? onFailure;

  final bool dense;

  PlaybackPreferences get _preferences =>
      preferences ?? session?.preferences ?? const PlaybackPreferences();

  Future<void> _apply(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      onFailure?.call();
    }
  }

  void _save(PlaybackPreferences next) => save?.call(next);

  double get _stroke => _preferences.danmakuStroke;
  double get _shadow => _preferences.danmakuShadow;

  /// 字号四档：0.8× / 1.0× / 1.25× / 1.5×。
  static const _scaleLabels = ['0.8×', '1.0×', '1.25×', '1.5×'];

  Widget _stepChips<T>({
    required String title,
    required String subtitle,
    required List<T> values,
    required List<String> labels,
    required T selected,
    required void Function(T) onPick,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(title, style: const TextStyle(fontSize: 16)),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (index, value) in values.indexed)
            ChoiceChip(
              label: Text(labels[index]),
              selected: selected == value,
              showCheckmark: false,
              shape: const StadiumBorder(),
              onSelected: (_) => onPick(value),
            ),
        ],
      ),
      const SizedBox(height: 4),
    ],
  );

  Widget _scaleTile() => _stepChips<double>(
    title: '字体大小',
    subtitle: '字号越大，屏幕上同时显示的行数越少',
    values: danmakuScaleSteps,
    labels: _scaleLabels,
    selected: _nearestStep(_preferences.danmakuScale, danmakuScaleSteps),
    onPick: (value) => _apply(
      () => session?.setDanmakuScale(value) ?? _asyncSave(scale: value),
    ),
  );

  /// 不透明度四档 + 静态预览（所见即所得，不滚动、不耗帧）。
  Widget _opacityTile() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _stepChips<double>(
        title: '不透明度',
        subtitle: '调低后弹幕更透，不挡画面',
        values: danmakuOpacitySteps,
        labels: danmakuOpacitySteps.map((v) => '${(v * 100).round()}%').toList(),
        selected: _nearestStep(_preferences.danmakuOpacity, danmakuOpacitySteps),
        onPick: (value) => _apply(
          () => session?.setDanmakuOpacity(value) ?? _asyncSave(opacity: value),
        ),
      ),
      _opacityPreview(),
    ],
  );

  Widget _opacityPreview() {
    final p = _preferences;
    final fontSize = (16.0 * p.danmakuScale);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '这是一条弹幕效果预览 🚀',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          shadows: const [Shadow(offset: Offset(0.8, 1), blurRadius: 1.5, color: Colors.black)],
        ).copyWith(color: Color(p.danmakuColor).withValues(alpha: p.danmakuOpacity)),
      ),
    );
  }

  /// 把任意值吸附到最近的离散档位，用于回显历史存档里的连续值。
  static double _nearestStep(double value, List<double> steps) {
    var best = steps.first;
    var bestDist = (value - best).abs();
    for (final s in steps.skip(1)) {
      final d = (value - s).abs();
      if (d < bestDist) {
        bestDist = d;
        best = s;
      }
    }
    return best;
  }

  Widget _strokeTile() => SliderTile(
    title: '描边',
    subtitle: _stroke == 0 ? '关闭' : '描边越粗字越突出',
    value: _stroke,
    min: danmakuStrokeMin,
    max: danmakuStrokeMax,
    divisions: 12,
    label: (value) => value == 0 ? '关闭' : value.toStringAsFixed(1),
    onChanged: (value) => _apply(
      () => session?.setDanmakuStroke(value) ?? _asyncSave(stroke: value),
    ),
  );

  Widget _shadowTile() => SliderTile(
    title: '阴影',
    subtitle: _shadow == 0 ? '关闭' : '阴影越浓字越清晰',
    value: _shadow,
    min: danmakuShadowMin,
    max: danmakuShadowMax,
    divisions: 12,
    label: (value) => value == 0 ? '关闭' : value.toStringAsFixed(1),
    onChanged: (value) => _apply(
      () => session?.setDanmakuShadow(value) ?? _asyncSave(shadow: value),
    ),
  );

  Widget _speedTile() => _stepChips<double>(
    title: '滚动速度',
    subtitle: '弹幕划过屏幕的快慢（约 11 / 8.5 / 6.5 秒）',
    values: danmakuSpeedSteps,
    labels: danmakuSpeedLabels,
    selected: _nearestStep(_preferences.danmakuSpeed, danmakuSpeedSteps),
    onPick: (value) => _apply(
      () => session?.setDanmakuSpeed(value) ?? _asyncSave(speed: value),
    ),
  );

  Future<void> _asyncSave({
    double? scale,
    int? color,
    double? opacity,
    double? stroke,
    double? shadow,
    bool? bold,
    DanmakuCoverage? coverage,
    double? speed,
    DanmakuMerge? merge,
    List<String>? words,
  }) async {
    _save(
      _preferences.copyWith(
        danmakuScale: scale,
        danmakuColor: color,
        danmakuOpacity: opacity,
        danmakuStroke: stroke,
        danmakuShadow: shadow,
        danmakuBold: bold,
        danmakuCoverage: coverage,
        danmakuSpeed: speed,
        danmakuMerge: merge,
        danmakuWords: words,
      ),
    );
  }

  Future<void> _editWords(BuildContext context) async {
    final words = await showDialog<List<String>>(
      context: context,
      builder: (_) => _WordsDialog(initial: _preferences.danmakuWords),
    );
    if (words == null) return;
    await _apply(
      () => session?.setDanmakuWords(words) ?? _asyncSave(words: words),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preferences = _preferences;
    final colors = Theme.of(context).colorScheme;
    final label = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(context, '外观'),
        _scaleTile(),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (index, color) in danmakuColors.indexed)
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: Color(color)),
                  label: Text(_colorLabels[index]),
                  selected: preferences.danmakuColor == color,
                  showCheckmark: false,
                  shape: const StadiumBorder(),
                  onSelected: (_) => _apply(
                    () =>
                        session?.setDanmakuColor(color) ??
                        _asyncSave(color: color),
                  ),
                ),
            ],
          ),
        ),
        _opacityTile(),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('加粗'),
          subtitle: const Text('加粗的字在亮背景上更清楚'),
          value: preferences.danmakuBold,
          onChanged: (value) => _apply(
            () => session?.setDanmakuBold(value) ?? _asyncSave(bold: value),
          ),
        ),
        _strokeTile(),
        _shadowTile(),
        _section(context, '滚动'),
        _speedTile(),
        _section(context, '合并重复'),
        Text(
          preferences.danmakuMerge == DanmakuMerge.off
              ? '关闭时每条弹幕单独滚动。'
              : '时间相近、文字完全相同的弹幕并成一条，后面标上出现的次数。',
          style: TextStyle(fontSize: 13, height: 1.4, color: label.color),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final merge in DanmakuMerge.values)
                ChoiceChip(
                  label: Text(merge.label),
                  selected: preferences.danmakuMerge == merge,
                  showCheckmark: false,
                  shape: const StadiumBorder(),
                  onSelected: (_) => _apply(
                    () =>
                        session?.setDanmakuMerge(merge) ??
                        _asyncSave(merge: merge),
                  ),
                ),
            ],
          ),
        ),
        _section(context, '显示区域'),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final coverage in DanmakuCoverage.values)
                ChoiceChip(
                  label: Text(coverage.label),
                  selected: preferences.danmakuCoverage == coverage,
                  showCheckmark: false,
                  shape: const StadiumBorder(),
                  onSelected: (_) => _apply(
                    () =>
                        session?.setDanmakuCoverage(coverage) ??
                        _asyncSave(coverage: coverage),
                  ),
                ),
            ],
          ),
        ),
        _section(context, '屏蔽词'),
        Text(
          preferences.danmakuWords.isEmpty
              ? '没有屏蔽词，含屏蔽词的弹幕会直接不显示。'
              : '已屏蔽 ${preferences.danmakuWords.length} 个词：${preferences.danmakuWords.join('、')}',
          style: TextStyle(fontSize: 13, height: 1.4, color: label.color),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FocusRing(
            radius: 20,
            child: OutlinedButton.icon(
              onPressed: () => _editWords(context),
              icon: const Icon(Icons.filter_alt_outlined, size: 18),
              label: const Text('管理屏蔽词'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: EdgeInsets.fromLTRB(0, dense ? 18 : 24, 0, 8),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _WordsDialog extends StatefulWidget {
  const _WordsDialog({required this.initial});
  final List<String> initial;

  @override
  State<_WordsDialog> createState() => _WordsDialogState();
}

class _WordsDialogState extends State<_WordsDialog> {
  late final _controller = TextEditingController();
  late List<String> _words = [...widget.initial];
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final word = _controller.text.trim();
    if (word.isEmpty) return;
    if (word.length > danmakuWordLength) {
      setState(() => _error = '单个屏蔽词最多 $danmakuWordLength 个字');
      return;
    }
    final key = normalizedSearchText(word);
    if (key.isEmpty) {
      setState(() => _error = '只有标点或空格的词无法匹配弹幕');
      return;
    }
    if (_words.any((entry) => normalizedSearchText(entry) == key)) {
      setState(() => _error = '这个词已经在列表里了');
      return;
    }
    if (_words.length >= danmakuWordLimit) {
      setState(() => _error = '最多只能添加 $danmakuWordLimit 个屏蔽词');
      return;
    }
    setState(() {
      _words = [..._words, word];
      _error = null;
    });
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('弹幕屏蔽词'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: FormTextField(
                    controller: _controller,
                    maxLength: danmakuWordLength,
                    decoration: const InputDecoration(
                      hintText: '输入要屏蔽的词',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                FilledButton(onPressed: _add, child: const Text('添加')),
              ],
            ),
            const SizedBox(height: 8),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  error,
                  style: TextStyle(fontSize: 13, color: colors.error),
                ),
              ),
            if (_words.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '还没有屏蔽词',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final word in _words)
                        InputChip(
                          label: Text(word),
                          onDeleted: () => setState(
                            () => _words = [
                              for (final entry in _words)
                                if (entry != word) entry,
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _words),
            child: const Text('保存'),
          ),
        ),
      ],
    );
  }
}
