import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../ranking_models.dart';
import '../../source_catalog.dart';
import '../app_scope.dart';
import '../player/playback_launcher.dart';
import '../widgets/cover_image.dart';
import '../widgets/drama_grid.dart';
import '../widgets/follow_button.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

/// 手机端「搜索」标签页：顶部搜索框 + 站源切换 + 默认首页资源，提交后显示搜索结果。
class SearchTab extends StatefulWidget {
  const SearchTab({super.key, required this.store, this.onCancel, this.feed});
  final LocalStore store;

  /// 点击「取消」返回首页。
  final VoidCallback? onCancel;

  /// 可选：由 AppShell 共享的首页数据源。
  final ExploreFeed? feed;

  @override
  State<SearchTab> createState() => SearchTabState();
}

class SearchTabState extends State<SearchTab> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  ExploreFeed? _explore;
  DramaFeed? _results;
  String _submitted = '';
  bool _ready = false;
  late AppRepository _repository;
  List<RankingItem> _hot = const [];
  int _hotGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _repository = AppScope.of(context).repository;
    _explore ??= widget.feed ?? ExploreFeed(_repository, widget.store);
    unawaited(_loadHot());
  }

  Future<void> _loadHot() async {
    final generation = ++_hotGeneration;
    try {
      final boards = await _repository.rankingBoards();
      final sourceBoards = [
        for (final board in boards)
          if (board.source == widget.store.source) board,
      ];
      final hotBoard =
          sourceBoards
              .where(
                (board) =>
                    board.name.contains('热') ||
                    board.name.contains('搜') ||
                    board.id.contains('hot'),
              )
              .firstOrNull ??
          sourceBoards.firstOrNull;
      if (hotBoard == null) return;
      final page = await _repository.rankings(hotBoard);
      if (!mounted || generation != _hotGeneration) return;
      setState(() => _hot = page.items.take(8).toList());
    } catch (_) {}
  }

  @override
  void dispose() {
    _results?.dispose();
    if (widget.feed == null) _explore?.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 由 AppShell 调用：切到搜索页时聚焦；带关键词时直接搜索。
  /// 不带关键词时回到默认视图（最近搜索 / 大家都在搜），避免停留在上次结果。
  void open(String query) {
    if (!mounted) return;
    if (query.trim().isEmpty) {
      _results?.dispose();
      _results = null;
      if (_submitted.isNotEmpty) {
        _submitted = '';
        _controller.clear();
        setState(() {});
      }
      _focus.requestFocus();
      return;
    }
    _submit(query);
  }

  void _submit(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    _controller.text = query;
    _focus.unfocus();
    unawaited(widget.store.rememberSearch(query).catchError((Object _) {}));
    _results?.dispose();
    final catalog = SourceCatalog(
      _repository,
      SourceSite.byId(widget.store.source),
    );
    final results = _results = DramaFeed(
      load: (page, _) => catalog.search(query, page: page),
    )..addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(results.reload());
    setState(() => _submitted = query);
  }

  void _open(Drama drama) => unawaited(
    openDrama(context, store: widget.store, drama: drama),
  );

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final television = form == FormFactor.television;
    final inset = switch (form) {
      FormFactor.phone => 16.0,
      FormFactor.pad || FormFactor.window => 24.0,
      FormFactor.television => televisionInset,
    };
    return Scaffold(
      // 键盘避让交给外层 AppShell 处理，保证底部菜单随键盘上升。
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(),
            _sources(),
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([_explore!, widget.store]),
                builder: (context, _) => _body(context, inset, television),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: SearchField(
              hint: '搜索短剧 / 演员',
              controller: _controller,
              focusNode: _focus,
              onSubmitted: _submit,
            ),
          ),
          TextButton(onPressed: widget.onCancel, child: const Text('取消')),
        ],
      ),
    );
  }

  Widget _sources() {
    final sources = widget.store.sources;
    if (sources.length < 2) return const SizedBox(height: 4);
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        itemCount: sources.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final site = sources[index];
          final selected = site.id == widget.store.source;
          return ChoiceChip(
            label: Text(
              site.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: selected,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              if (site.id != widget.store.source) {
                unawaited(
                  widget.store
                      .setSource(site.id)
                      .then((_) => _loadHot())
                      .catchError((Object _) {}),
                );
              }
            },
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, double inset, bool television) {
    final results = _results;
    if (results != null) return _resultsBody(context, inset, television);
    return _homeFeed(context, inset, television);
  }

  Widget _homeFeed(BuildContext context, double inset, bool television) {
    final explore = _explore!;
    final source = explore.source;
    final discovery = _discoverySlivers(context, inset);
    if (source == null) {
      return CustomScrollView(
        slivers: [
          ...discovery,
          const SliverFillRemaining(
            hasScrollBody: false,
            child: StatusView(
              title: '暂无可用站源',
              message: '请在 我的 › 模块 中开启站源',
              icon: Icons.public_off_rounded,
            ),
          ),
        ],
      );
    }
    final feed = explore.feed!;
    final items = feed.items;
    // 红果推荐榜（AI 剧榜）：前 3 名放大卡片，其余两列紧凑列表。
    if (explore.recommending) {
      return _rankingBody(context, feed, items, inset, television, discovery);
    }
    return LayoutBuilder(
      builder: (context, constraints) => AutoLoadMore(
        feed: feed,
        child: CustomScrollView(
          slivers: [
            // 最近搜索、大家都在搜放在最上方，进入搜索页即可见。
            ...discovery,
            if (items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _feedStatus(feed, inset),
              )
            else ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
                sliver: DramaSliverGrid(
                  width: constraints.maxWidth - inset * 2,
                  items: items,
                  rankOf: (drama) => explore.rankIn(explore.tab, drama),
                  heroScope: 'drama',
                  showScore: explore.tab.id != recommendTab.id,
                  exploreBlur: true,
                  onOpen: _open,
                  onMore: (drama) => quickFollow(context, widget.store, drama),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                sliver: SliverToBoxAdapter(child: FeedFooter(feed: feed)),
              ),
            ],
            SliverPadding(
              padding: EdgeInsets.only(bottom: television ? 27 : 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feedStatus(DramaFeed feed, double inset) {
    if (feed.loading) {
      return DramaGridSkeleton(
        key: const ValueKey('loading'),
        padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
      );
    }
    if (feed.error.isNotEmpty) {
      return StatusView(
        key: const ValueKey('error'),
        title: '暂时无法加载',
        message: feed.error,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => feed.reload(force: true),
      );
    }
    return StatusView(
      key: const ValueKey('empty'),
      title: '这里还没有剧',
      message: '换一个站源看看',
      icon: Icons.inbox_outlined,
      action: '刷新',
      onAction: () => feed.reload(force: true),
    );
  }

  List<Widget> _discoverySlivers(BuildContext context, double inset) {
    final recent = widget.store.recentSearches;
    final hot = _hot;
    if (recent.isEmpty && hot.isEmpty) return const [];
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (recent.isNotEmpty) ...[
                _RecentSearchesSection(
                  recent: recent,
                  onSearch: _submit,
                  onClear: () => widget.store
                      .clearRecentSearches()
                      .catchError((Object _) {}),
                ),
                if (hot.isNotEmpty) const SizedBox(height: 20),
              ],
              if (hot.isNotEmpty)
                _HotSearchesSection(items: hot, onSearch: _submit),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _rankingBody(
    BuildContext context,
    DramaFeed feed,
    List<Drama> items,
    double inset,
    bool television,
    List<Widget> discovery,
  ) {
    final topThree = items.take(3).toList();
    final rest = items.skip(3).toList();
    final rankOf = {
      for (final (index, drama) in items.indexed) drama.id: index + 1,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - inset * 2;
        return AutoLoadMore(
          feed: feed,
          child: CustomScrollView(
            slivers: [
              ...discovery,
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
                sliver: SliverToBoxAdapter(
                  child: _TopThreeRow(items: topThree, width: width, onOpen: _open),
                ),
              ),
              if (rest.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          mainAxisExtent: 96,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final drama = rest[index];
                      return _RankListItem(
                        drama: drama,
                        rank: rankOf[drama.id] ?? index + 4,
                        onOpen: _open,
                      );
                    }, childCount: rest.length),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                sliver: SliverToBoxAdapter(child: FeedFooter(feed: feed)),
              ),
              SliverPadding(
                padding: EdgeInsets.only(bottom: television ? 27 : 16),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _resultsBody(BuildContext context, double inset, bool television) {
    final results = _results!;
    if (results.items.isEmpty) {
      if (results.loading) {
        return const StatusView.loading(
          key: ValueKey('loading'),
          title: '正在搜索',
        );
      }
      if (results.error.isNotEmpty) {
        return StatusView(
          key: const ValueKey('error'),
          title: '搜索失败',
          message: results.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => results.reload(),
        );
      }
      return StatusView(
        key: const ValueKey('empty'),
        title: '没有找到「$_submitted」',
        message: '换个关键词试试',
        icon: Icons.search_off_rounded,
      );
    }
    return LayoutBuilder(
      key: ValueKey(('results', _submitted)),
      builder: (context, constraints) => AutoLoadMore(
        feed: results,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
              sliver: DramaSliverGrid(
                width: constraints.maxWidth - inset * 2,
                items: results.items,
                heroScope: 'drama',
                onOpen: _open,
                onMore: (drama) => quickFollow(context, widget.store, drama),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                8,
                inset,
                television ? 27 : 16,
              ),
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: results)),
            ),
          ],
        ),
      ),
    );
  }
}

const _heatColor = Color(0xFFFF5A5F);

class _TopThreeRow extends StatelessWidget {
  const _TopThreeRow({
    required this.items,
    required this.width,
    required this.onOpen,
  });
  final List<Drama> items;
  final double width;
  final ValueChanged<Drama> onOpen;

  @override
  Widget build(BuildContext context) {
    const gap = 10.0;
    final cardWidth = (width - gap * 2) / 3;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, drama) in items.indexed) ...[
          if (index > 0) const SizedBox(width: gap),
          SizedBox(
            width: cardWidth,
            child: _TopThreeCard(drama: drama, rank: index + 1, onOpen: onOpen),
          ),
        ],
      ],
    );
  }
}

class _TopThreeCard extends StatelessWidget {
  const _TopThreeCard({
    required this.drama,
    required this.rank,
    required this.onOpen,
  });
  final Drama drama;
  final int rank;
  final ValueChanged<Drama> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onOpen(drama),
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: DramaCover(drama: drama, radius: 12),
                ),
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [.5, 1],
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .7),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(left: 0, top: 0, child: RankBadge(rank: rank)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _metric(drama),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _metric(Drama drama) {
    final parts = [
      if (drama.episodes > 0) '${drama.episodes}集',
      if (drama.heat.isNotEmpty) drama.heat,
    ];
    return parts.join(' · ');
  }
}

class _RankListItem extends StatelessWidget {
  const _RankListItem({
    required this.drama,
    required this.rank,
    required this.onOpen,
  });
  final Drama drama;
  final int rank;
  final ValueChanged<Drama> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onOpen(drama),
      borderRadius: BorderRadius.circular(10),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            height: 88,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: DramaCover(drama: drama, radius: 8, details: false),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .62),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(8),
                        bottomRight: Radius.circular(6),
                      ),
                    ),
                    child: Text(
                      '$rank',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  drama.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text.rich(
                  TextSpan(
                    children: [
                      if (drama.heat.isNotEmpty)
                        TextSpan(
                          text: drama.heat,
                          style: const TextStyle(
                            color: _heatColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (drama.heat.isNotEmpty && drama.episodes > 0)
                        const TextSpan(text: ' · '),
                      if (drama.episodes > 0)
                        TextSpan(
                          text: '${drama.episodes}集',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentSearchesSection extends StatelessWidget {
  const _RecentSearchesSection({
    required this.recent,
    required this.onSearch,
    required this.onClear,
  });
  final List<String> recent;
  final ValueChanged<String> onSearch;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '最近搜索',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '清空',
              onPressed: onClear,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final query in recent)
              ActionChip(
                avatar: const Icon(Icons.history_rounded, size: 16),
                label: Text(query),
                onPressed: () => onSearch(query),
              ),
          ],
        ),
      ],
    );
  }
}

class _HotSearchesSection extends StatelessWidget {
  const _HotSearchesSection({required this.items, required this.onSearch});
  final List<RankingItem> items;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '大家都在搜',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        for (final item in items)
          InkWell(
            onTap: () => onSearch(item.drama.title),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${item.rank}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: item.rank <= 3
                            ? _heatColor
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.drama.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (item.metric.isNotEmpty)
                    Text(
                      item.metric,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    )
                  else if (item.drama.heat.isNotEmpty)
                    Text(
                      item.drama.heat,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
