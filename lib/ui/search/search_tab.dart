import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_catalog.dart';
import '../app_scope.dart';
import '../player/playback_launcher.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _repository = AppScope.of(context).repository;
    _explore ??= widget.feed ?? ExploreFeed(_repository, widget.store);
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
  void open(String query) {
    if (!mounted) return;
    if (query.trim().isEmpty) {
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
                  widget.store.setSource(site.id).catchError((Object _) {}),
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
    if (source == null) {
      return const StatusView(
        title: '暂无可用站源',
        message: '请在 我的 › 模块 中开启站源',
        icon: Icons.public_off_rounded,
      );
    }
    final feed = explore.feed!;
    final items = feed.items;
    if (items.isEmpty) {
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
    return LayoutBuilder(
      builder: (context, constraints) => AutoLoadMore(
        feed: feed,
        child: CustomScrollView(
          slivers: [
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
              padding: EdgeInsets.fromLTRB(
                inset,
                8,
                inset,
                television ? 27 : 16,
              ),
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: feed)),
            ),
          ],
        ),
      ),
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
