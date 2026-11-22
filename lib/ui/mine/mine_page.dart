import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../merge_queue.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../app_scope.dart';
import '../downloads/downloads_page.dart';
import '../find/find_page.dart';
import '../modules/modules_page.dart';
import '../settings/settings_page.dart';
import '../settings/settings_sections.dart';
import '../shell/app_shell.dart';
import '../widgets/focus_ring.dart';
import '../widgets/group_card.dart';
import '../widgets/page_header.dart';

class MinePage extends StatelessWidget {
  const MinePage({
    super.key,
    required this.store,
    required this.downloads,
    required this.converter,
    required this.merges,
    required this.entryFocus,
    required this.onExitUp,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final DownloadConverter converter;
  final MergeQueue merges;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => switch (AppScope.formFactorOf(context)) {
          FormFactor.phone => _phone(context),
          FormFactor.pad || FormFactor.window => _wide(context),
          FormFactor.television => _television(context),
        },
      ),
    ),
  );

  void _openDownloads(BuildContext context) => openPage<void>(
    context,
    (_) => DownloadsPage(
      store: store,
      downloads: downloads,
      converter: converter,
      merges: merges,
    ),
  );

  void _openModules(BuildContext context) =>
      openPage<void>(context, (_) => ModulesPage(store: store));

  void _openNight(BuildContext context) => openPage<void>(
    context,
    (_) => FindPage(
      store: store,
      entryFocus: entryFocus,
      onExitUp: onExitUp,
      adultOnly: true,
    ),
  );

  void _openGroup(BuildContext context, SettingsGroup group) =>
      openSettingsGroup(context, store, group);

  Widget _entries(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      if (!store.adultLocked)
        GroupCard(
          children: [
            SettingsTile(
              icon: Icons.nightlight_round,
              title: '夜剧',
              onTap: () => _openNight(context),
            ),
          ],
        ),
      GroupCard(
        children: [
          for (final group in const [
            SettingsGroup.appearance,
            SettingsGroup.playback,
            SettingsGroup.danmaku,
          ])
            SettingsTile(
              icon: group.icon,
              title: group.label,
              onTap: () => _openGroup(context, group),
            ),
        ],
      ),
      GroupCard(
        children: [
          SettingsTile(
            icon: Icons.download_rounded,
            title: '下载',
            onTap: () => _openDownloads(context),
          ),
          SettingsTile(
            icon: Icons.extension_outlined,
            title: '模块',
            onTap: () => _openModules(context),
          ),
        ],
      ),
      GroupCard(
        children: [
          for (final group in const [
            SettingsGroup.proxy,
            SettingsGroup.diagnostics,
          ])
            SettingsTile(
              icon: group.icon,
              title: group.label,
              onTap: () => _openGroup(context, group),
            ),
        ],
      ),
      GroupCard(
        children: [
          SettingsTile(
            icon: SettingsGroup.about.icon,
            title: SettingsGroup.about.label,
            onTap: () => _openGroup(context, SettingsGroup.about),
          ),
        ],
      ),
    ],
  );

  Widget _phone(BuildContext context) => ListView(
    padding: EdgeInsets.only(
      bottom: MediaQuery.paddingOf(context).bottom + 16,
    ),
    children: [
      const PageHeader(title: '我的'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _entries(context),
      ),
    ],
  );

  Widget _wide(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 32),
    children: [
      const PageHeader(title: '我的'),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              _entries(context),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _television(BuildContext context) {
    final page = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(televisionInset, 14, televisionInset, 27),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height -
              televisionInset -
              41,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 22,
          children: [
            Row(
              spacing: 20,
              children: [
                Expanded(
                  child: _TelevisionEntry(
                    icon: Icons.download_rounded,
                    primary: true,
                    focusNode: entryFocus,
                    title: '下载',
                    subtitle: '下载任务、下载设置与存储',
                    onTap: () => _openDownloads(context),
                  ),
                ),
                Expanded(
                  child: _TelevisionEntry(
                    icon: Icons.extension_outlined,
                    title: '模块',
                    subtitle: '安装与管理站源',
                    onTap: () => _openModules(context),
                  ),
                ),
                Expanded(
                  child: _TelevisionEntry(
                    icon: Icons.settings_outlined,
                    title: '设置',
                    subtitle: '外观、播放、弹幕、代理与诊断',
                    onTap: () => openPage<void>(
                      context,
                      (_) => SettingsPage(store: store),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyUpEvent ||
            event.logicalKey != LogicalKeyboardKey.arrowUp) {
          return KeyEventResult.ignored;
        }
        final moved = FocusManager.instance.primaryFocus?.focusInDirection(
          TraversalDirection.up,
        );
        if (moved != true) onExitUp();
        return KeyEventResult.handled;
      },
      child: page,
    );
  }
}

class _TelevisionEntry extends StatelessWidget {
  const _TelevisionEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.focusNode,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 20,
      scale: 1,
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          focusColor: Colors.transparent,
          onTap: onTap,
          child: SizedBox(
            height: 84,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                spacing: 16,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: primary
                          ? colors.primaryContainer
                          : colors.secondaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: primary ? 26 : 24,
                      color: primary
                          ? colors.onPrimaryContainer
                          : colors.onSecondaryContainer,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 2,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
