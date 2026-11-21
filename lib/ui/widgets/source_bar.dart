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

  /// 首页源快捷切换：最多展示 5 个，其余由圆形「更多」图标承载。
  final List<SourceSite> sources;
  final String currentSourceId;
  final void Function(String id)? onSelectSource;
  final VoidCallback? onMoreSources;

  /// 手机首页搜索框只读：点击跳转到搜索页，不再原地输入。
  final bool readOnlySearch;

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

  /// 手机首页：顶部搜索框 + 源快捷切换（5 个）+ 其余源圆形更多图标。
  Widget _phoneHomeHeader(
    BuildContext context,
    String hint,
    Widget switcher,
  ) {
    final colors = Theme.of(context).colorScheme;
    final hasChips = sources.isNotEmpty && onSelectSource != null;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: readOnlySearch
                    ? SearchField(
                        hint: hint,
                        controller: searchController,
                        readOnly: true,
                        onTap: onOpenSearch,
                        onSubmitted: onSearchSubmitted,
                      )
                    : _RecentSearchField(
                        width: double.infinity,
                        hint: hint,
                        controller: searchController,
                        recent: recentSearches,
                        onSubmitted: onSearchSubmitted,
                        onForget: onForgetSearch,
                      ),
              ),
              if (leading.isNotEmpty) ...leading,
              switcher,
            ],
          ),
          if (hasChips) const SizedBox(height: 8),
          if (hasChips)
            SizedBox(
              height: 34,
              child: Row(
                children: [
                  Expanded(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: sources.take(5).length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final site = sources[index];
                        final selected = site.id == currentSourceId;
                        return ChoiceChip(
                          label: Text(
                            site.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          selected: selected,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          onSelected: (_) => onSelectSource?.call(site.id),
                        );
                      },
                    ),
                  ),
                  if (sources.length > 5)
                    Builder(
                      builder: (anchor) => Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: IconButton.filledTonal(
                            onPressed: onMoreSources != null
                                ? () => onMoreSources!()
                                : () => onSwitchSource(anchor),
                            icon: const Icon(Icons.more_horiz_rounded, size: 20),
                            tooltip: '更多站源',
                            padding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ),
                  ...actions,
                ],
              ),
            ),
        ],
      ),
    );
  }
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
