import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/matched_user_picker_sheet.dart';
import '../../../shared/widgets/share_group_card.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/simple_profile_view_screen.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../profile/data/user_repository.dart' show blockedUserIdsProvider;
import '../data/group_repository.dart';
import '../models/group_membership_model.dart';
import '../models/group_model.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';

final _groupDetailRepoProvider =
    Provider<GroupRepository>((ref) => GroupRepository());

final groupDetailProvider =
    FutureProvider.autoDispose.family<GroupModel?, String>((ref, groupId) {
  return ref.watch(_groupDetailRepoProvider).fetchGroup(groupId);
});

final groupMembersProvider = FutureProvider.autoDispose
    .family<List<GroupMembershipModel>, String>((ref, groupId) {
  return ref.watch(_groupDetailRepoProvider).fetchMembers(groupId);
});

final groupPendingRequestsProvider = FutureProvider.autoDispose
    .family<List<GroupMembershipModel>, String>((ref, groupId) {
  return ref.watch(_groupDetailRepoProvider).fetchPendingRequests(groupId);
});

final myGroupMembershipProvider = FutureProvider.autoDispose
    .family<GroupMembershipModel?, String>((ref, groupId) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return null;
  return ref
      .watch(_groupDetailRepoProvider)
      .fetchMyMembership(groupId, user.userId);
});

class GroupDetailScreen extends ConsumerWidget {
  final String groupId;
  const GroupDetailScreen({super.key, required this.groupId});

  void _refresh(WidgetRef ref) {
    ref.invalidate(groupDetailProvider(groupId));
    ref.invalidate(groupMembersProvider(groupId));
    ref.invalidate(myGroupMembershipProvider(groupId));
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    try {
      final result =
          await ref.read(_groupDetailRepoProvider).requestJoin(groupId);
      _refresh(ref);
      if (context.mounted) {
        final status = result['status'] as String?;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(status == 'pending' ? '参加申請を送りました' : 'グループに参加しました'),
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('参加に失敗しました: $e')));
      }
    }
  }

  Future<void> _editGroup(
      BuildContext context, WidgetRef ref, GroupModel group) async {
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => CreateGroupScreen(editGroup: group)),
    );
    if (updated == true) _refresh(ref);
  }

  Future<void> _deleteGroup(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('このグループを削除しますか？'),
        content: const Text('メンバー・チャット履歴もすべて削除されます。この操作は取り消せません。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(_groupDetailRepoProvider).deleteGroup(groupId);
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('削除しました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('削除に失敗しました: $e')));
      }
    }
  }

  Future<void> _transferOwnership(
      BuildContext context, WidgetRef ref, GroupMembershipModel member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('${member.nickname ?? '名無し'}さんにオーナー権限を譲渡しますか？'),
        content: const Text('譲渡すると、あなたはオーナーではなくなります。この操作は取り消せません。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('譲渡する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(_groupDetailRepoProvider)
          .transferOwnership(groupId, member.userId);
      _refresh(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('オーナー権限を譲渡しました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('譲渡に失敗しました: $e')));
      }
    }
  }

  Future<void> _setLeader(BuildContext context, WidgetRef ref,
      GroupMembershipModel member, bool toLeader) async {
    try {
      await ref
          .read(_groupDetailRepoProvider)
          .promoteMember(groupId, member.userId, toLeader: toLeader);
      _refresh(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(toLeader ? 'リーダーにしました' : 'リーダーを解除しました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('変更に失敗しました: $e')));
      }
    }
  }

  Future<void> _kickMember(BuildContext context, WidgetRef ref,
      GroupMembershipModel member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('${member.nickname ?? '名無し'}さんを除名しますか？'),
        content: const Text('このグループから除名されます。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('除名する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(_groupDetailRepoProvider)
          .kickMember(groupId, member.userId);
      _refresh(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('除名しました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('除名に失敗しました: $e')));
      }
    }
  }

  Future<void> _invite(BuildContext context, WidgetRef ref,
      List<GroupMembershipModel> members) async {
    final excludeIds = members.map((m) => m.userId).toSet();
    final pickedUserId = await showMatchedUserPicker(context, ref,
        title: 'グループに招待する相手を選ぶ', excludeUserIds: excludeIds);
    if (pickedUserId == null) return;
    try {
      await ref
          .read(_groupDetailRepoProvider)
          .inviteUser(groupId, pickedUserId);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('招待を送りました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('招待に失敗しました: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupAsync = ref.watch(groupDetailProvider(groupId));
    final membersAsync = ref.watch(groupMembersProvider(groupId));
    final myMembershipAsync = ref.watch(myGroupMembershipProvider(groupId));
    final myUserId = ref.watch(authNotifierProvider).value?.userId;

    // invalidate直後（他ユーザーのリアルタイム更新含む）も直前のデータを
    // 表示し続け、画面全体がローディング表示に差し替わる「チカチカ」を防ぐ。
    Widget buildBody(GroupModel? group) {
      if (group == null) {
        return const Center(
            child: Text('グループが見つかりません',
                style: TextStyle(color: AppColors.textMuted)));
      }
      final myMembership = myMembershipAsync.value;
      final isOwner = group.ownerId == myUserId;
      final isMember = myMembership?.status == GroupMembershipStatus.member;
      final isPending = myMembership?.status == GroupMembershipStatus.pending;
      final isInvited = myMembership?.status == GroupMembershipStatus.invited;
      final isLeader = myMembership?.isLeader ?? false;
      // kick_group_member RPCの権限ルールと一致させる：
      // open は全メンバー可、それ以外はオーナー/リーダーのみ。
      final canManageMembers =
          isOwner || isLeader || group.joinMode == GroupJoinMode.open;
      final canInvite = isMember &&
          (group.joinMode != GroupJoinMode.inviteOnly ||
              !group.inviteRestrictedToLeader ||
              isOwner ||
              isLeader);

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              (group.iconUrl != null && group.iconUrl!.isNotEmpty)
                  ? ClipOval(
                      child: SignedStorageImage(
                        storedReference: group.iconUrl!,
                        defaultBucket: 'group-photos',
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      ),
                    )
                  : CircleAvatar(
                      radius: 28,
                      backgroundColor: AppColors.primary.withOpacity(0.1),
                      child: const Icon(Icons.group,
                          color: AppColors.primary, size: 28),
                    ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      '${group.joinMode.label} ・ ${group.memberCount}人',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (group.description != null && group.description!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(group.description!,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 14, height: 1.6)),
          ],
          const SizedBox(height: 20),
          if (isOwner)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('あなたがオーナーです',
                      style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                OutlinedButton.icon(
                  onPressed: () => _editGroup(context, ref, group),
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('編集', style: TextStyle(fontSize: 13)),
                ),
                OutlinedButton.icon(
                  onPressed: () => _deleteGroup(context, ref),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('削除', style: TextStyle(fontSize: 13)),
                ),
              ],
            )
          else if (isMember)
            OutlinedButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: AppColors.surface,
                    title: const Text('グループを退会しますか？'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('キャンセル')),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.error),
                        child: const Text('退会する'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  try {
                    await ref
                        .read(_groupDetailRepoProvider)
                        .leaveGroup(groupId);
                    _refresh(ref);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('退会に失敗しました: $e')),
                      );
                    }
                  }
                }
              },
              child: const Text('グループを退会'),
            )
          else if (isPending)
            const Text('参加承認待ちです', style: TextStyle(color: AppColors.textMuted))
          else if (isInvited)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      try {
                        await ref
                            .read(_groupDetailRepoProvider)
                            .respondToInvite(myMembership!.membershipId, true);
                        _refresh(ref);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('招待への応答に失敗しました: $e')),
                          );
                        }
                      }
                    },
                    child: const Text('招待を受ける'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      try {
                        await ref
                            .read(_groupDetailRepoProvider)
                            .respondToInvite(myMembership!.membershipId, false);
                        _refresh(ref);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('招待への応答に失敗しました: $e')),
                          );
                        }
                      }
                    },
                    child: const Text('辞退'),
                  ),
                ),
              ],
            )
          else if (group.joinMode.value == 'invite_only')
            const Text('このグループは招待制です',
                style: TextStyle(color: AppColors.textMuted))
          else
            ElevatedButton(
              onPressed: () => _join(context, ref),
              child: Text(
                  group.joinMode.value == 'approval' ? '参加を申請する' : 'グループに参加する'),
            ),
          if (isMember) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => GroupChatScreen(
                          groupId: groupId, groupName: group.name)),
                ),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('グループチャットを開く'),
              ),
            ),
          ],
          if (isOwner) ...[
            const SizedBox(height: 24),
            Consumer(builder: (context, ref, _) {
              final pendingAsync =
                  ref.watch(groupPendingRequestsProvider(groupId));
              return pendingAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (e, _) => const SizedBox.shrink(),
                data: (pending) {
                  if (pending.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('参加申請 (${pending.length}件)',
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      ...pending.map((p) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                _MemberAvatar(
                                    url: p.avatarUrl, nickname: p.nickname),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: Text(p.nickname ?? '名無し',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600))),
                                IconButton(
                                  icon: const Icon(Icons.check_circle,
                                      color: AppColors.primary),
                                  onPressed: () async {
                                    try {
                                      await ref
                                          .read(_groupDetailRepoProvider)
                                          .approveJoinRequest(
                                              p.membershipId, true);
                                      ref.invalidate(
                                          groupPendingRequestsProvider(
                                              groupId));
                                      ref.invalidate(
                                          groupMembersProvider(groupId));
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(SnackBar(
                                                content:
                                                    Text('承認に失敗しました: $e')));
                                      }
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.cancel,
                                      color: AppColors.error),
                                  onPressed: () async {
                                    try {
                                      await ref
                                          .read(_groupDetailRepoProvider)
                                          .approveJoinRequest(
                                              p.membershipId, false);
                                      ref.invalidate(
                                          groupPendingRequestsProvider(
                                              groupId));
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(SnackBar(
                                                content:
                                                    Text('却下に失敗しました: $e')));
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                          )),
                    ],
                  );
                },
              );
            }),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              const Text('メンバー',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              if (canInvite)
                TextButton.icon(
                  onPressed: () =>
                      _invite(context, ref, membersAsync.value ?? []),
                  icon: const Icon(Icons.person_add_alt, size: 16),
                  label: const Text('招待する', style: TextStyle(fontSize: 13)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          membersAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary)),
            ),
            error: (e, _) => const Text('メンバー一覧の取得に失敗しました',
                style: TextStyle(color: AppColors.textMuted)),
            data: (members) => Column(
              children: members
                  .map((m) {
                    final blockedIds =
                        ref.watch(blockedUserIdsProvider).value ??
                            const <String>{};
                    final isBlocked = blockedIds.contains(m.userId);
                    return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: isBlocked
                                    ? null
                                    : () => showUserProfile(
                                        context, ref, m.userId),
                                child: Row(
                                  children: [
                                    _MemberAvatar(
                                        url: isBlocked ? null : m.avatarUrl,
                                        nickname: isBlocked
                                            ? 'ー'
                                            : (m.nickname ?? 'U')),
                                    const SizedBox(width: 10),
                                    Expanded(
                                        child: Text(
                                            isBlocked
                                                ? 'ブロック中のユーザー'
                                                : (m.nickname ?? '名無し'),
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600,
                                                color: isBlocked
                                                    ? AppColors.textMuted
                                                    : null))),
                                  ],
                                ),
                              ),
                            ),
                            if (m.isOwner)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text('オーナー',
                                    style: TextStyle(
                                        color: AppColors.primary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600)),
                              )
                            else ...[
                              if (m.isLeader)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.textMuted
                                          .withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text('リーダー',
                                        style: TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600)),
                                  ),
                                ),
                              if (isOwner || canManageMembers)
                                PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert,
                                      size: 20, color: AppColors.textMuted),
                                  onSelected: (v) {
                                    switch (v) {
                                      case 'transfer':
                                        _transferOwnership(context, ref, m);
                                        break;
                                      case 'promote':
                                        _setLeader(context, ref, m, true);
                                        break;
                                      case 'demote':
                                        _setLeader(context, ref, m, false);
                                        break;
                                      case 'kick':
                                        _kickMember(context, ref, m);
                                        break;
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    if (isOwner)
                                      PopupMenuItem(
                                        value: m.isLeader ? 'demote' : 'promote',
                                        child: Text(m.isLeader
                                            ? 'リーダーを解除'
                                            : 'リーダーにする'),
                                      ),
                                    if (isOwner)
                                      const PopupMenuItem(
                                        value: 'transfer',
                                        child: Text('オーナー権限を譲渡'),
                                      ),
                                    if (canManageMembers)
                                      const PopupMenuItem(
                                        value: 'kick',
                                        child: Text('グループから除名',
                                            style: TextStyle(
                                                color: AppColors.error)),
                                      ),
                                  ],
                                ),
                            ],
                          ],
                        ),
                      );
                  })
                  .toList(),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        title: 'グループ',
        actions: [
          // 招待制のグループは外部SNSでの集客に適さないため共有ボタンを出さない
          if (groupAsync.value != null &&
              groupAsync.value!.joinMode != GroupJoinMode.inviteOnly)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: 'SNSで共有',
                onPressed: () => shareGroup(context, groupAsync.value!),
              ),
            ),
        ],
      ),
      body: groupAsync.hasValue
          ? buildBody(groupAsync.value)
          : groupAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: AppColors.primary)),
              error: (e, _) => ErrorView(
                  message: '読み込みに失敗しました', onRetry: () => _refresh(ref)),
              data: buildBody,
            ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  final String? url;
  final String? nickname;
  const _MemberAvatar({this.url, this.nickname});

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) {
      return ClipOval(
        child: SignedStorageImage(
          storedReference: url!,
          defaultBucket: 'profile-photos',
          width: 36,
          height: 36,
          fit: BoxFit.cover,
        ),
      );
    }
    return CircleAvatar(
      radius: 18,
      backgroundColor: AppColors.primary.withOpacity(0.15),
      child: Text(
        (nickname != null && nickname!.isNotEmpty)
            ? nickname!.substring(0, 1).toUpperCase()
            : 'U',
        style: const TextStyle(
            color: AppColors.primary,
            fontSize: 13,
            fontWeight: FontWeight.w800),
      ),
    );
  }
}
