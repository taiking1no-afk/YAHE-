import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../features/ads/banner_ad_widget.dart';
import '../../../shared/widgets/ad_grid_helper.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/user_groups_section.dart' show myGroupsProvider;
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../chat/data/chat_prefs.dart';
import '../../chat/data/chat_prefs_provider.dart';
import '../data/group_repository.dart';
import '../models/group_message_model.dart';
import '../models/group_model.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'group_detail_screen.dart';

final _groupRepoProvider =
    Provider<GroupRepository>((ref) => GroupRepository());

final groupSearchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

/// 「マイグループのみ」フィルタ（自分が参加済みのグループだけに絞り込む）。
final groupMyGroupsOnlyProvider =
    StateProvider.autoDispose<bool>((ref) => false);

final groupsProvider = FutureProvider.autoDispose<List<GroupModel>>((ref) {
  final query = ref.watch(groupSearchQueryProvider);
  return ref.watch(_groupRepoProvider).fetchGroups(searchQuery: query);
});

/// 自分がオーナーのグループごとの参加申請(pending)件数（一覧のバッジ表示・下タブのバッジ用）。
final groupMyOwnedPendingCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) {
  final myUserId = ref.watch(authNotifierProvider).value?.userId;
  if (myUserId == null) return Future.value(const {});
  return ref.watch(_groupRepoProvider).fetchMyOwnedPendingCounts(myUserId);
});

final groupChatSummariesProvider =
    FutureProvider.autoDispose<List<GroupChatSummary>>((ref) {
  return ref.watch(_groupRepoProvider).fetchMyGroupChatSummaries();
});

final myInvitedGroupsProvider =
    FutureProvider.autoDispose<List<InvitedGroupEntry>>((ref) {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return Future.value(const []);
  return ref.watch(_groupRepoProvider).fetchMyInvitedGroups(user.userId);
});

enum GroupSortMode { recommended, newest, mostMembers }

extension GroupSortModeX on GroupSortMode {
  String get label => switch (this) {
        GroupSortMode.recommended => 'おすすめ順',
        GroupSortMode.newest => '新規順',
        GroupSortMode.mostMembers => 'ユーザーが多い順',
      };
}

final groupSortModeProvider = StateProvider.autoDispose<GroupSortMode>(
    (ref) => GroupSortMode.recommended);

/// マッチ済みの相手が所属しているグループのID一覧（おすすめ並べ替え用）。
final matchedUserGroupIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return Future.value(const {});
  return ref.watch(_groupRepoProvider).fetchMatchedUserGroupIds(user.userId);
});

List<GroupModel> _sortGroups(List<GroupModel> groups, GroupSortMode mode,
    {Set<String> matchedGroupIds = const {}, String? myArea}) {
  final sorted = List<GroupModel>.of(groups);
  switch (mode) {
    case GroupSortMode.newest:
      sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    case GroupSortMode.mostMembers:
      sorted.sort((a, b) => b.memberCount.compareTo(a.memberCount));
    case GroupSortMode.recommended:
      int score(GroupModel g) {
        var s = 0;
        if (matchedGroupIds.contains(g.groupId)) s += 2;
        if (myArea != null && myArea.isNotEmpty && g.ownerArea == myArea)
          s += 1;
        return s;
      }

      sorted.sort((a, b) {
        final diff = score(b) - score(a);
        if (diff != 0) return diff;
        return b.memberCount.compareTo(a.memberCount);
      });
  }
  return sorted;
}

String _groupPrefKey(String groupId) => 'group:$groupId';

class GroupListScreen extends ConsumerStatefulWidget {
  /// 統合タブ（ChatGroupHubScreen）内に埋め込む場合はtrue。
  final bool embedded;
  const GroupListScreen({super.key, this.embedded = false});

  @override
  ConsumerState<GroupListScreen> createState() => _GroupListScreenState();
}

class _GroupListScreenState extends ConsumerState<GroupListScreen> {
  Set<String> _pinned = {};
  Set<String> _muted = {};
  Map<String, DateTime> _hiddenAt = {};
  bool _searchCollapsed = true;
  bool _prefsLoaded = false;

  // グループ検索は「マイグループチャット」と違い初期状態が畳んである
  // （デフォルト=畳む）ため、逆に「開いたことがある」ことを記録するキーにする。
  static const _searchSectionExpandedKey = 'group_search_section_expanded';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final pinned = await ChatPrefs.pinnedIds();
    final muted = await ChatPrefs.mutedIds();
    final hiddenAt = await ChatPrefs.hiddenAt();
    final collapsedSections = await ChatPrefs.collapsedSections();
    if (mounted) {
      setState(() {
        _pinned = pinned;
        _muted = muted;
        _hiddenAt = hiddenAt;
        _searchCollapsed =
            !collapsedSections.contains(_searchSectionExpandedKey);
        _prefsLoaded = true;
      });
    }
  }

  Future<void> _toggleSearchCollapsed() async {
    final next = !_searchCollapsed;
    await ChatPrefs.setSectionCollapsed(_searchSectionExpandedKey, !next);
    setState(() => _searchCollapsed = next);
  }

  Future<void> _togglePin(GroupChatSummary g) async {
    final key = _groupPrefKey(g.groupId);
    final next = !_pinned.contains(key);
    await ChatPrefs.setPinned(key, next);
    setState(() => next ? _pinned.add(key) : _pinned.remove(key));
  }

  Future<void> _toggleMute(GroupChatSummary g) async {
    final key = _groupPrefKey(g.groupId);
    final next = !_muted.contains(key);
    await ChatPrefs.setMuted(key, next);
    setState(() => next ? _muted.add(key) : _muted.remove(key));
    ref.invalidate(mutedChatIdsProvider);
  }

  Future<void> _hideChat(GroupChatSummary g) async {
    final key = _groupPrefKey(g.groupId);
    await ChatPrefs.hide(key);
    setState(() => _hiddenAt[key] = DateTime.now().toUtc());
  }

  Future<void> _respondInvite(InvitedGroupEntry entry, bool accept) async {
    try {
      await GroupRepository().respondToInvite(entry.membershipId, accept);
      ref.invalidate(myInvitedGroupsProvider);
      ref.invalidate(groupsProvider);
      ref.invalidate(groupChatSummariesProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(accept ? '「${entry.group.name}」に参加しました' : '辞退しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('処理に失敗しました: $e')));
      }
    }
  }

  Future<void> _openGroupChat(GroupChatSummary g) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              GroupChatScreen(groupId: g.groupId, groupName: g.groupName)),
    );
    final key = _groupPrefKey(g.groupId);
    if (_hiddenAt.containsKey(key)) {
      await ChatPrefs.unhide(key);
      setState(() => _hiddenAt.remove(key));
    }
    ref.invalidate(groupChatSummariesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(groupsProvider);
    final chatsAsync = ref.watch(groupChatSummariesProvider);
    final invitedAsync = ref.watch(myInvitedGroupsProvider);
    final sortMode = ref.watch(groupSortModeProvider);
    final matchedGroupIds =
        ref.watch(matchedUserGroupIdsProvider).value ?? const {};
    final myArea = ref.watch(authNotifierProvider).value?.area;
    final myUserId = ref.watch(authNotifierProvider).value?.userId;
    final pendingCounts = ref.watch(groupMyOwnedPendingCountsProvider).value ??
        const <String, int>{};
    final myGroupsOnly = ref.watch(groupMyGroupsOnlyProvider);
    final myGroupIds = myUserId == null
        ? const <String>{}
        : (ref.watch(myGroupsProvider(myUserId)).value ?? const [])
            .map((g) => g.groupId)
            .toSet();

    Future<void> createGroup() async {
      final created = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
      );
      if (created == true) {
        ref.invalidate(groupsProvider);
        ref.invalidate(groupChatSummariesProvider);
      }
    }

    // 「マイグループチャット」欄などの上部セクションが多く伸びると、
    // 固定高のColumn+Expandedの組み合わせでは画面全体がその分だけ
    // 下にはみ出し、下端がわずかにオーバーフローしてしまう
    // （デバッグ表示で黄黒縞のオーバーフロー警告が出る不具合）。
    // ページ全体を1つのスクロール領域にまとめ、伸びた分は普通に
    // スクロールできるようにする。
    final body = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: invitedAsync.maybeWhen(
            data: (invites) => invites.isEmpty
                ? const SizedBox.shrink()
                : _InvitedGroupsSection(
                    invites: invites, onRespond: _respondInvite),
            orElse: () => const SizedBox.shrink(),
          ),
        ),
        // ─── グループ検索（折りたたみ可能・初期状態は畳んである）
        SliverToBoxAdapter(
          child: _CollapsibleSectionHeader(
            label: 'グループ検索',
            collapsed: _searchCollapsed,
            onToggle: _toggleSearchCollapsed,
          ),
        ),
        if (!_searchCollapsed) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'グループを検索',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => ref
                          .read(groupSearchQueryProvider.notifier)
                          .state = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<GroupSortMode>(
                    icon: const Icon(Icons.sort),
                    tooltip: '並べ替え',
                    initialValue: sortMode,
                    onSelected: (m) =>
                        ref.read(groupSortModeProvider.notifier).state = m,
                    itemBuilder: (context) => [
                      for (final m in GroupSortMode.values)
                        PopupMenuItem(
                          value: m,
                          child: Row(
                            children: [
                              if (m == sortMode)
                                const Icon(Icons.check,
                                    size: 16, color: AppColors.primary)
                              else
                                const SizedBox(width: 16),
                              const SizedBox(width: 8),
                              Text(m.label),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    icon: const Icon(Icons.add),
                    tooltip: 'グループを作成',
                    onPressed: createGroup,
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  label: const Text('マイグループのみ'),
                  avatar: const Icon(Icons.groups_outlined, size: 16),
                  selected: myGroupsOnly,
                  onSelected: (v) =>
                      ref.read(groupMyGroupsOnlyProvider.notifier).state = v,
                ),
              ),
            ),
          ),
          // invalidate直後(他ユーザーのリアルタイム更新含む)も直前のデータを
          // 表示し続け、画面全体がローディング表示に差し替わる「チカチカ」を防ぐ。
          groupsAsync.hasValue
              ? _buildGroupsListSliver(groupsAsync.value!, sortMode,
                  matchedGroupIds, myArea, myUserId, pendingCounts,
                  myGroupsOnly: myGroupsOnly, myGroupIds: myGroupIds)
              : groupsAsync.when(
                  loading: () => const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary)),
                  ),
                  error: (e, _) => SliverFillRemaining(
                    hasScrollBody: false,
                    child: ErrorView(
                      message: '読み込みに失敗しました',
                      onRetry: () => ref.invalidate(groupsProvider),
                    ),
                  ),
                  data: (_) =>
                      const SliverToBoxAdapter(child: SizedBox.shrink()),
                ),
        ],
        // ─── マイグループチャット
        if (_prefsLoaded)
          SliverToBoxAdapter(
            child: chatsAsync.maybeWhen(
              data: (chats) => _MyGroupChatsSection(
                chats: chats,
                pinned: _pinned,
                muted: _muted,
                hiddenAt: _hiddenAt,
                onOpen: _openGroupChat,
                onTogglePin: _togglePin,
                onToggleMute: _toggleMute,
                onHide: _hideChat,
              ),
              orElse: () => const SizedBox.shrink(),
            ),
          ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: 'グループ'),
      body: body,
    );
  }

  Widget _buildGroupsListSliver(
    List<GroupModel> rawGroups,
    GroupSortMode sortMode,
    Set<String> matchedGroupIds,
    String? myArea,
    String? myUserId,
    Map<String, int> pendingCounts, {
    required bool myGroupsOnly,
    required Set<String> myGroupIds,
  }) {
    final filteredGroups = myGroupsOnly
        ? rawGroups.where((g) => myGroupIds.contains(g.groupId)).toList()
        : rawGroups;
    if (filteredGroups.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(myGroupsOnly ? '参加しているグループがありません' : 'グループがありません',
              style: const TextStyle(color: AppColors.textMuted)),
        ),
      );
    }
    final groups = _sortGroups(filteredGroups, sortMode,
        matchedGroupIds: matchedGroupIds, myArea: myArea);
    final items = interleaveItemsWithAds<GroupModel>(groups);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            if (i.isOdd) {
              return const Divider(height: 1, color: AppColors.border);
            }
            final item = items[i ~/ 2];
            if (item == 'ad') return const InlineBannerAdCard();
            final g = item as GroupModel;
            final pendingCount =
                g.ownerId == myUserId ? (pendingCounts[g.groupId] ?? 0) : 0;
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              leading: _GroupIcon(url: g.iconUrl, name: g.name),
              title: Text(g.name,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${g.joinMode.label} ・ ${g.memberCount}人',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMuted),
                  ),
                  if (pendingCount > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      '参加希望者がいます ($pendingCount)',
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.warning,
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ],
              ),
              trailing:
                  const Icon(Icons.chevron_right, color: AppColors.textMuted),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => GroupDetailScreen(groupId: g.groupId)),
                );
                ref.invalidate(groupChatSummariesProvider);
              },
            );
          },
          childCount: items.isEmpty ? 0 : items.length * 2 - 1,
        ),
      ),
    );
  }
}

/// 折りたたみ可能なセクションの見出し行（グループ検索など）。
class _CollapsibleSectionHeader extends StatelessWidget {
  final String label;
  final bool collapsed;
  final VoidCallback onToggle;

  const _CollapsibleSectionHeader({
    required this.label,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700),
              ),
            ),
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 20,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// 自分宛の未応答グループ招待を最上部に表示し、その場で参加・辞退できるようにする。
class _InvitedGroupsSection extends StatelessWidget {
  final List<InvitedGroupEntry> invites;
  final void Function(InvitedGroupEntry entry, bool accept) onRespond;
  const _InvitedGroupsSection({required this.invites, required this.onRespond});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primary.withOpacity(0.06),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              'グループに招待されています（${invites.length}件）',
              style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ),
          ...invites.map((entry) => InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          GroupDetailScreen(groupId: entry.group.groupId)),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _GroupIcon(
                              url: entry.group.iconUrl, name: entry.group.name),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.group.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${entry.group.joinMode.label} ・ ${entry.group.memberCount}人',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                            onPressed: () => onRespond(entry, false),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              minimumSize: const Size(0, 36),
                            ),
                            child: const Text('辞退',
                                style: TextStyle(fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () => onRespond(entry, true),
                            style: ElevatedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              minimumSize: const Size(0, 36),
                            ),
                            child: const Text('参加',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )),
          const Divider(height: 1, color: AppColors.border),
        ],
      ),
    );
  }
}

/// 自分が参加中のグループのチャット一覧（ピン留め・ミュート・削除のスワイプ操作つき）。
class _MyGroupChatsSection extends StatelessWidget {
  final List<GroupChatSummary> chats;
  final Set<String> pinned;
  final Set<String> muted;
  final Map<String, DateTime> hiddenAt;
  final ValueChanged<GroupChatSummary> onOpen;
  final ValueChanged<GroupChatSummary> onTogglePin;
  final ValueChanged<GroupChatSummary> onToggleMute;
  final ValueChanged<GroupChatSummary> onHide;

  const _MyGroupChatsSection({
    required this.chats,
    required this.pinned,
    required this.muted,
    required this.hiddenAt,
    required this.onOpen,
    required this.onTogglePin,
    required this.onToggleMute,
    required this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    if (chats.isEmpty) return const SizedBox.shrink();

    // 削除（非表示）した時刻より後に新着メッセージ（自分・相手どちらの
    // 送信でも）があれば再表示する。unreadCountだけで判定すると、
    // 自分がそのグループへ新規送信した場合はカウントされず
    // （自分の送信は自分にとって未読になり得ないため）、削除後に
    // 自分で送っても一覧に戻ってこない不具合になっていた。
    final visible = chats.where((c) {
      final hiddenSince = hiddenAt[_groupPrefKey(c.groupId)];
      if (hiddenSince == null) return true;
      final lastMessageAt = c.lastMessageAt;
      return lastMessageAt != null && lastMessageAt.isAfter(hiddenSince);
    }).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    final indexed = visible.asMap().entries.toList()
      ..sort((a, b) {
        final aPinned = pinned.contains(_groupPrefKey(a.value.groupId));
        final bPinned = pinned.contains(_groupPrefKey(b.value.groupId));
        if (aPinned != bPinned) return aPinned ? -1 : 1;
        return a.key.compareTo(b.key);
      });
    final sorted = indexed.map((e) => e.value).toList();

    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'マイグループチャット',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ),
          ...sorted.map((g) {
              final key = _groupPrefKey(g.groupId);
              final isPinned = pinned.contains(key);
              final isMuted = muted.contains(key);
              return Slidable(
                key: ValueKey(g.groupId),
                endActionPane: ActionPane(
                  motion: const ScrollMotion(),
                  extentRatio: 0.75,
                  children: [
                    SlidableAction(
                      onPressed: (_) => onTogglePin(g),
                      backgroundColor: AppColors.warning,
                      foregroundColor: Colors.white,
                      icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                      label: isPinned ? '解除' : 'ピン留め',
                    ),
                    SlidableAction(
                      onPressed: (_) => onToggleMute(g),
                      backgroundColor: AppColors.textMuted,
                      foregroundColor: Colors.white,
                      icon: isMuted
                          ? Icons.notifications
                          : Icons.notifications_off,
                      label: isMuted ? '解除' : 'ミュート',
                    ),
                    SlidableAction(
                      onPressed: (_) => onHide(g),
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      icon: Icons.delete_outline,
                      label: '削除',
                    ),
                  ],
                ),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: _GroupIcon(url: g.groupIconUrl, name: g.groupName),
                  title: Row(
                    children: [
                      if (isPinned) ...[
                        const Icon(Icons.push_pin,
                            size: 13, color: AppColors.warning),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(g.groupName,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      if (isMuted) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.notifications_off,
                            size: 13, color: AppColors.textMuted),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    g.lastMessageBody ?? 'まだメッセージがありません',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 13),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (g.lastMessageAt != null)
                        Text(DateFormat('M/d HH:mm').format(g.lastMessageAt!),
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 11)),
                      if (g.unreadCount > 0 && !isMuted) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: const BoxDecoration(
                              color: AppColors.primary, shape: BoxShape.circle),
                          constraints: const BoxConstraints(minWidth: 18),
                          child: Text(
                            '${g.unreadCount}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ],
                  ),
                  onTap: () => onOpen(g),
                ),
              );
            }),
          const Divider(height: 1, color: AppColors.border),
        ],
      ),
    );
  }
}

class _GroupIcon extends StatelessWidget {
  final String? url;
  final String name;
  const _GroupIcon({this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) {
      return ClipOval(
        child: SignedStorageImage(
          storedReference: url!,
          defaultBucket: 'group-photos',
          width: 44,
          height: 44,
          fit: BoxFit.cover,
        ),
      );
    }
    return CircleAvatar(
      backgroundColor: AppColors.primary.withOpacity(0.1),
      child: const Icon(Icons.group, color: AppColors.primary),
    );
  }
}
