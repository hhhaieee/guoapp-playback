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
  });
  final LocalStore store;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  @override
  State<FindPage> createState() => _FindPageState();
}

class _FindPageState extends State<FindPage> {
  int _index = 0;

  bool get _showHistory => widget.store.historyTab;

  @override
  Widget build(BuildContext context) {
    if (!_showHistory) {
      return FollowPage(
        store: widget.store,
        entryFocus: widget.entryFocus,
        onExitUp: widget.onExitUp,
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
                _chip('追剧', 0),
                const SizedBox(width: 8),
                _chip('历史', 1),
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
                FollowPage(
                  store: widget.store,
                  entryFocus: widget.entryFocus,
                  onExitUp: widget.onExitUp,
                ),
                HistoryPage(store: widget.store, root: true),
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
