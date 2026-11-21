import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../follow/follow_page.dart';
import '../history/history_page.dart';

/// 手机端「找剧」标签页：把「追剧」与「历史」合并到一个入口。
class FindPage extends StatefulWidget {
  const FindPage({
    super.key,
    required this.store,
    required this.entryFocus,
    required this.onExitUp,
    this.adultOnly,
    this.onOpenSearch,
  });
  final LocalStore store;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  /// 是否仅显示 18+ 片源：null 不过滤，true 仅 18+，false 仅非 18+。
  final bool? adultOnly;

  /// 手机端追剧页右下角悬浮搜索按钮回调。
  final VoidCallback? onOpenSearch;

  @override
  State<FindPage> createState() => _FindPageState();
}

class _FindPageState extends State<FindPage> {
  int _index = 0;

  bool get _showHistory => widget.store.historyTab;

  @override
  Widget build(BuildContext context) {
    final body = _buildBody();
    // 从「我的」页以「夜剧」入口进入时带返回按钮；作为底部标签页时不带。
    if (widget.adultOnly == true) {
      return Scaffold(
        appBar: AppBar(title: const Text('夜剧')),
        body: body,
      );
    }
    return body;
  }

  Widget _buildBody() {
    if (!_showHistory) {
      return FollowPage(
        store: widget.store,
        entryFocus: widget.entryFocus,
        onExitUp: widget.onExitUp,
        adultOnly: widget.adultOnly,
        onOpenSearch: widget.onOpenSearch,
      );
    }
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                _chip('历史', 0),
                const SizedBox(width: 8),
                _chip('追剧', 1),
              ],
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: IndexedStack(
              index: _index,
              children: [
                HistoryPage(
                  store: widget.store,
                  root: true,
                  adultOnly: widget.adultOnly,
                ),
                FollowPage(
                  store: widget.store,
                  entryFocus: widget.entryFocus,
                  onExitUp: widget.onExitUp,
                  adultOnly: widget.adultOnly,
                  onOpenSearch: widget.onOpenSearch,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, int index) {
    final colors = Theme.of(context).colorScheme;
    final selected = _index == index;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      selectedColor: colors.secondaryContainer,
      labelStyle: TextStyle(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
      ),
      onSelected: (_) => setState(() => _index = index),
    );
  }
}
