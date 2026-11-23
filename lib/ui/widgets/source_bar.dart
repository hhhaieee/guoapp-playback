import 'dart:math';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../app_scope.dart';
import 'bar_button.dart';
import 'page_header.dart';
import 'search_field.dart';

class SourceBar extends StatelessWidget {
  const SourceBar({
    super.key,
    required this.source,
    required this.onSwitchSource,
    required this.onOpenSearch,
    required this.onSearchSubmitted,
    this.searchController,
    this.recentSearches = const [],
    this.onForgetSearch,
    this.televisionLeading,
    this.leading = const [],
    this.actions = const [],
    this.sources = const [],
    this.currentSourceId = '',
    this.onSelectSource,
    this.onMoreSources,
    this.readOnlySearch = false,
    this.spin,
  });
  final List<Widget> leading;
  final String source;
  final void Function(BuildContext anchor) onSwitchSource;
  final VoidCallback onOpenSearch;
  final ValueChanged<String> onSearchSubmitted;
  final TextEditingController? searchController;
  final List<String> recentSearches;
  final ValueChanged<String>? onForgetSearch;
  final Widget? televisionLeading;
  final List<Widget> actions;

  /// 首页源快捷切换：全部标签横向滑动，可左右滑出更多。
  final List<SourceSite> sources;
  final String currentSourceId;
  final void Function(String id)? onSelectSource;
  final VoidCallback? onMoreSources;

  /// 手机首页搜索框只读：点击跳转到搜索页，不再原地输入。
  final bool readOnlySearch;

  /// 分类栏横滑时驱动「更多站源」球体同步旋转。
  final ValueNotifier<double>? spin;

  static final _idleSpin = ValueNotifier<double>(0);

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final hint = '在 $source 中搜索';
    final switcher = Builder(
      builder: (anchor) => BarButton(
        icon: Icons.public_rounded,
        tooltip: '切换站源',
        onPressed: () => onSwitchSource(anchor),
      ),
    );
    final search = BarButton(
      icon: Icons.search_rounded,
      tooltip: hint,
      onPressed: onOpenSearch,
    );
    return switch (form) {
      FormFactor.phone => _phoneHomeHeader(context, hint, switcher),
      FormFactor.pad || FormFactor.window => PageHeader(
        title: source,
        actions: [
          ...leading,
          switcher,
          const SizedBox(width: 4),
          _RecentSearchField(
            width: MediaQuery.sizeOf(context).width >= 900 ? 320 : 240,
            hint: hint,
            controller: searchController,
            recent: recentSearches,
            onSubmitted: onSearchSubmitted,
            onForget: onForgetSearch,
          ),
          const SizedBox(width: 4),
          ...actions,
        ],
      ),
      FormFactor.television => SizedBox(
        height: 48,
        child: Row(
          spacing: 10,
          children: [
            ?televisionLeading,
            const Spacer(),
            Text(
              source,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            switcher,
            search,
            ...actions,
          ],
        ),
      ),
    };
  }

  /// 手机首页：全部源标签横向滑动，可左右滑出更多；切换源后自动滚到选中项。
  /// 末尾保留圆形「更多」入口打开完整站源面板。搜索入口在右下角悬浮按钮。
  Widget _phoneHomeHeader(
    BuildContext context,
    String hint,
    Widget switcher,
  ) {
    final colors = Theme.of(context).colorScheme;
    final hasChips = sources.isNotEmpty && onSelectSource != null;
    if (!hasChips) {
      return Container(
        color: colors.surface,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(children: [...leading, ...actions]),
      );
    }
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  _SourceChips(
                    sources: sources,
                    currentSourceId: currentSourceId,
                    onSelectSource: onSelectSource!,
                    spin: spin,
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: 10,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              colors.surface.withValues(alpha: 0),
                              colors.surface.withValues(alpha: 0),
                              colors.surface,
                            ],
                            stops: const [0, 0.55, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: spin ?? _idleSpin,
              builder: (context, value, _) => Transform.rotate(
                angle: value / 40,
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: Tooltip(
                    message: '更多站源',
                    child: ClipOval(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onMoreSources ?? () => onSwitchSource(context),
                          child: ColorFiltered(
                            colorFilter: _ballTint(
                              Theme.of(context).colorScheme.primary,
                            ),
                            child: Image.asset(
                              'assets/images/star_ball.png',
                              width: 34,
                              height: 34,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ...leading,
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 首页源标签：全部横向滑动，末尾附「更多」入口；切换源后把选中项滚到可见。
class _SourceChips extends StatefulWidget {
  const _SourceChips({
    required this.sources,
    required this.currentSourceId,
    required this.onSelectSource,
    this.spin,
  });
  final List<SourceSite> sources;
  final String currentSourceId;
  final ValueChanged<String> onSelectSource;
  final ValueNotifier<double>? spin;

  @override
  State<_SourceChips> createState() => _SourceChipsState();
}

class _SourceChipsState extends State<_SourceChips> {
  final _controller = ScrollController();
  final _keys = <String, GlobalKey>{};

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_spun);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible());
  }

  void _spun() => widget.spin?.value = _controller.offset;

  @override
  void didUpdateWidget(covariant _SourceChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentSourceId != widget.currentSourceId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible());
    }
  }

  void _ensureVisible() {
    if (!mounted) return;
    final target = _keyFor(widget.currentSourceId).currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_spun);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      itemCount: widget.sources.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final site = widget.sources[index];
        final selected = site.id == widget.currentSourceId;
        return Container(
          key: _keyFor(site.id),
          child: ChoiceChip(
            label: Text(
              site.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: selected,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onSelected: (_) => widget.onSelectSource(site.id),
          ),
        );
      },
    );
  }
}

ColorFilter _ballTint(Color primary) {
  final hue = HSLColor.fromColor(primary);
  if (hue.saturation < 0.12) {
    return ColorFilter.matrix(_saturationMatrix(0.12));
  }
  return ColorFilter.matrix(_hueRotateMatrix((hue.hue - 190) * pi / 180));
}

List<double> _saturationMatrix(double saturation) {
  const lr = 0.213, lg = 0.715, lb = 0.072;
  final keep = 1 - saturation;
  return <double>[
    lr * keep + saturation, lg * keep, lb * keep, 0, 0,
    lr * keep, lg * keep + saturation, lb * keep, 0, 0,
    lr * keep, lg * keep, lb * keep + saturation, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

List<double> _hueRotateMatrix(double angle) {
  final c = cos(angle);
  final s = sin(angle);
  return <double>[
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.072, 0, 0,
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.072 + s * 0.072, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

class _RecentSearchField extends StatefulWidget {
  const _RecentSearchField({
    required this.width,
    required this.hint,
    required this.controller,
    required this.recent,
    required this.onSubmitted,
    required this.onForget,
  });
  final double width;
  final String hint;
  final TextEditingController? controller;
  final List<String> recent;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String>? onForget;

  @override
  State<_RecentSearchField> createState() => _RecentSearchFieldState();
}

class _RecentSearchFieldState extends State<_RecentSearchField> {
  final _ownController = TextEditingController();
  final _focus = FocusNode();
  final _overlay = OverlayPortalController()..show();
  final _link = LayerLink();
  var _active = false;

  TextEditingController get _controller => widget.controller ?? _ownController;

  @override
  void dispose() {
    _ownController.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _pick(String query) {
    _focus.unfocus();
    widget.onSubmitted(query);
  }

  Widget _options(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      if (!_active || _controller.text.isNotEmpty || widget.recent.isEmpty) {
        return const SizedBox.shrink();
      }
      return CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 4),
        child: Align(
          alignment: Alignment.topLeft,
          child: TextFieldTapRegion(
            child: SizedBox(
              width: widget.width,
              child: Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    children: [
                      for (final query in widget.recent)
                        GestureDetector(
                          onSecondaryTap: () => widget.onForget?.call(query),
                          child: ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.history_rounded,
                              size: 18,
                            ),
                            title: Text(
                              query,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _pick(query),
                            onLongPress: () => widget.onForget?.call(query),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (value) => setState(() => _active = value),
    child: CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _overlay,
        overlayChildBuilder: _options,
        child: SizedBox(
          width: widget.width,
          child: SearchField(
            hint: widget.hint,
            controller: _controller,
            focusNode: _focus,
            onSubmitted: widget.onSubmitted,
          ),
        ),
      ),
    ),
  );
}
