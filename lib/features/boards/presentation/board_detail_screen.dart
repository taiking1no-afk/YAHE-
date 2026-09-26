import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../../shared/widgets/matched_user_picker_sheet.dart';
import '../../../shared/widgets/report_dialog.dart';
import '../../../shared/widgets/share_board_post_card.dart';
import '../../../shared/widgets/simple_profile_view_screen.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../chat/data/chat_repository.dart';
import '../../groups/presentation/group_chat_screen.dart';
import '../../match/data/match_repository.dart';
import '../../vehicle/models/vehicle.dart';
import '../data/board_repository.dart';
import '../models/board_participation_model.dart';
import '../models/board_post_model.dart';
import 'create_board_post_screen.dart';

final _boardDetailRepoProvider =
    Provider<BoardRepository>((ref) => BoardRepository());

/// 参加/興味ありボタンの多重タップ防止用。処理中はtrueにしてボタンを無効化する。
final _boardActionBusyProvider =
    StateProvider.family<bool, String>((ref, postId) => false);

final boardPostDetailProvider =
    FutureProvider.autoDispose.family<BoardPostModel?, String>((ref, postId) {
  return ref.watch(_boardDetailRepoProvider).fetchPost(postId);
});

final boardParticipantsProvider = FutureProvider.autoDispose
    .family<List<BoardParticipationModel>, String>((ref, postId) {
  return ref.watch(_boardDetailRepoProvider).fetchParticipants(postId);
});

final boardPendingRequestsProvider = FutureProvider.autoDispose
    .family<List<BoardParticipationModel>, String>((ref, postId) {
  return ref.watch(_boardDetailRepoProvider).fetchPendingRequests(postId);
});

final boardAttendingMatchesProvider =
    FutureProvider.autoDispose.family<Set<String>, String>((ref, postId) {
  return ref.watch(_boardDetailRepoProvider).fetchAttendingMatchUserIds(postId);
});

final myBoardParticipationProvider = FutureProvider.autoDispose
    .family<BoardParticipationModel?, String>((ref, postId) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return null;
  return ref
      .watch(_boardDetailRepoProvider)
      .fetchMyParticipation(postId, user.userId);
});

class BoardDetailScreen extends ConsumerWidget {
  final String postId;
  const BoardDetailScreen({super.key, required this.postId});

  void _refresh(WidgetRef ref) {
    ref.invalidate(boardPostDetailProvider(postId));
    ref.invalidate(boardParticipantsProvider(postId));
    ref.invalidate(myBoardParticipationProvider(postId));
    ref.invalidate(boardAttendingMatchesProvider(postId));
    ref.invalidate(boardPendingRequestsProvider(postId));
  }

  Future<void> _approveRequest(BuildContext context, WidgetRef ref,
      String participationId, bool approve) async {
    try {
      await ref
          .read(_boardDetailRepoProvider)
          .approveJoinRequest(participationId, approve);
      _refresh(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(approve ? '参加を承認しました' : '参加を却下しました')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('処理に失敗しました: $e')));
      }
    }
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final busyNotifier = ref.read(_boardActionBusyProvider(postId).notifier);
    if (busyNotifier.state) return; // 連打防止
    busyNotifier.state = true;
    try {
      final result = await ref.read(_boardDetailRepoProvider).join(postId);
      _refresh(ref);
      if (context.mounted) {
        final status = result['status'] as String?;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(status == 'pending' ? '参加申請を送りました' : '参加しました！'),
        ));
      }
    } catch (e) {
      if (context.mounted) {
        final msg = e.toString().contains('capacity_full')
            ? '定員に達しています'
            : e.toString().contains('event_ended')
                ? 'このイベントは終了しています'
                : '参加に失敗しました';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      busyNotifier.state = false;
    }
  }

  Future<void> _interest(BuildContext context, WidgetRef ref) async {
    final busyNotifier = ref.read(_boardActionBusyProvider(postId).notifier);
    if (busyNotifier.state) return; // 連打防止
    busyNotifier.state = true;
    try {
      await ref.read(_boardDetailRepoProvider).expressInterest(postId);
      _refresh(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('興味ありに登録しました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('失敗しました: $e')));
      }
    } finally {
      busyNotifier.state = false;
    }
  }

  Future<void> _respondInvite(BuildContext context, WidgetRef ref,
      String participationId, bool accept) async {
    try {
      await ref
          .read(_boardDetailRepoProvider)
          .respondToInvite(participationId, accept);
      _refresh(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(accept ? '参加しました！' : '辞退しました')));
      }
    } catch (e) {
      if (context.mounted) {
        final msg = e.toString().contains('capacity_full')
            ? '定員に達しています'
            : e.toString().contains('event_ended')
                ? 'このイベントは終了しています'
                : '処理に失敗しました';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('参加を辞退しますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('辞退する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(_boardDetailRepoProvider).leave(postId);
      _refresh(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('辞退しました')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('処理に失敗しました: $e')));
      }
    }
  }

  Future<void> _invite(BuildContext context, WidgetRef ref, BoardPostModel post,
      List<BoardParticipationModel> participants) async {
    final excludeIds = participants
        .where((p) => p.status == BoardParticipationStatus.joined)
        .map((p) => p.userId)
        .toSet();
    final pickedUserId = await showMatchedUserPicker(context, ref,
        title: '招待する相手を選ぶ', excludeUserIds: excludeIds);
    if (pickedUserId == null) return;
    try {
      await ref.read(_boardDetailRepoProvider).invite(postId, pickedUserId);
      // マッチ済み同士のチャットにも「招待しました」メッセージを残す（ベストエフォート）。
      try {
        final myUserId = ref.read(authNotifierProvider).value?.userId;
        if (myUserId != null) {
          final match = await MatchRepository()
              .fetchMatchByOtherUserId(myUserId, pickedUserId);
          if (match != null) {
            await ChatRepository()
                .sendBoardInvite(match.matchId, postId, post.title);
          }
        }
      } catch (_) {}
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

  Future<void> _openParticipantChat(
      BuildContext context, WidgetRef ref, BoardPostModel post) async {
    String? groupId = post.chatGroupId;
    if (groupId == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('参加者チャットを作成しますか？'),
          content: Text(
            post.scheduledAt != null
                ? '参加者だけが入れるチャットです。開催日（${DateFormat('M月d日').format(post.scheduledAt!)}）の翌日に終了します。'
                : '参加者だけが入れるチャットです。',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('キャンセル')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('作成する')),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        groupId =
            await ref.read(_boardDetailRepoProvider).createPostChat(postId);
        _refresh(ref);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('作成に失敗しました: $e')));
        }
        return;
      }
    }
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => GroupChatScreen(
              groupId: groupId!, groupName: '${post.title} の参加者チャット')),
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, BoardPostModel post) async {
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => CreateBoardPostScreen(editPost: post)),
    );
    if (updated == true) _refresh(ref);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('この募集を削除しますか？'),
        content: const Text('参加者・興味ありの記録もすべて削除されます。この操作は取り消せません。'),
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
      await ref.read(_boardDetailRepoProvider).deletePost(postId);
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postAsync = ref.watch(boardPostDetailProvider(postId));
    final participantsAsync = ref.watch(boardParticipantsProvider(postId));
    final attendingMatchesAsync =
        ref.watch(boardAttendingMatchesProvider(postId));
    final myParticipation =
        ref.watch(myBoardParticipationProvider(postId)).value;
    final myUserId = ref.watch(authNotifierProvider).value?.userId;
    // Gear Rの「インサイトアクティビティ」用に閲覧数を記録する（サーバー側で重複排除）
    ref.read(_boardDetailRepoProvider).recordPostView(postId);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        title: '募集詳細',
        actions: [
          // 招待制の募集は外部SNSでの集客に適さないため共有ボタンを出さない。
          // 終了済みの募集も共有すると「参加者募集中！」という文言のまま
          // 出てしまい実態と合わないため、あわせて出さない。
          if (postAsync.value != null &&
              postAsync.value!.visibility != BoardVisibility.inviteOnly &&
              !postAsync.value!.isEnded)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: 'SNSで共有',
                onPressed: () => shareBoardPost(context, postAsync.value!),
              ),
            ),
          if (postAsync.value?.organizerId == myUserId) ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '編集',
              onPressed: () => _edit(context, ref, postAsync.value!),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.error),
              tooltip: '削除',
              onPressed: () => _delete(context, ref),
            ),
          ] else if (postAsync.value != null)
            IconButton(
              icon: const Icon(Icons.flag_outlined),
              tooltip: '通報',
              onPressed: () => showReportDialog(context,
                  targetType: 'board_post', boardPostId: postId),
            ),
        ],
      ),
      body: _buildBody(context, ref, postAsync, participantsAsync,
          attendingMatchesAsync, myParticipation, myUserId),
    );
  }

  // invalidate直後（他ユーザーのリアルタイム更新含む）も直前のデータを
  // 表示し続け、画面全体がローディング表示に差し替わる「チカチカ」を防ぐ。
  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<BoardPostModel?> postAsync,
    AsyncValue<List<BoardParticipationModel>> participantsAsync,
    AsyncValue<Set<String>> attendingMatchesAsync,
    BoardParticipationModel? myParticipation,
    String? myUserId,
  ) {
    if (!postAsync.hasValue) {
      return postAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.primary)),
        error: (e, _) =>
            ErrorView(message: '読み込みに失敗しました', onRetry: () => _refresh(ref)),
        data: (_) => const SizedBox.shrink(),
      );
    }
    {
      final post = postAsync.value;
      if (post == null) {
        return const Center(
            child: Text('見つかりませんでした',
                style: TextStyle(color: AppColors.textMuted)));
      }
      final isOrganizer = post.organizerId == myUserId;
      final isJoined =
          myParticipation?.status == BoardParticipationStatus.joined;
      final isPending =
          myParticipation?.status == BoardParticipationStatus.pending;
      final isInvited =
          myParticipation?.status == BoardParticipationStatus.invited;
      final isFull =
          post.capacity != null && post.joinedCount >= post.capacity!;
      final actionBusy = ref.watch(_boardActionBusyProvider(postId));

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (post.imagePath != null && post.imagePath!.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SignedStorageImage(
                storedReference: post.imagePath!,
                defaultBucket: 'board-photos',
                width: double.infinity,
                height: 200,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(post.postType.label,
              style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(post.title,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          if (post.scheduledAt != null)
            _InfoRow(
                icon: Icons.event,
                text: DateFormat('yyyy年M月d日 HH:mm').format(post.scheduledAt!)),
          if (post.meetingPlaceText != null &&
              post.meetingPlaceText!.isNotEmpty)
            _InfoRow(icon: Icons.place_outlined, text: post.meetingPlaceText!),
          _InfoRow(
            icon: Icons.people_outline,
            text: post.capacity != null
                ? '${post.joinedCount} / ${post.capacity}人（参加）'
                : '${post.joinedCount}人参加中',
          ),
          _InfoRow(icon: Icons.lock_outline, text: post.visibility.label),
          if (post.detail != null && post.detail!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(post.detail!,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 14, height: 1.6)),
          ],
          if (post.routeDetail != null && post.routeDetail!.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('ルート',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(post.routeDetail!,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13, height: 1.6)),
          ],
          const SizedBox(height: 20),
          if (post.isEnded)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                  color: AppColors.textMuted.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  const Icon(Icons.event_busy,
                      color: AppColors.textMuted, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      post.daysUntilAutoDelete != null
                          ? 'このイベントは終了しています（あと${post.daysUntilAutoDelete}日でこの投稿は自動削除されます）'
                          : 'このイベントは終了しています',
                      style: const TextStyle(
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          if (isOrganizer)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8)),
              child: const Text('あなたが主催者です',
                  style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            )
          else if (isJoined)
            Row(
              children: [
                const Expanded(
                  child: Text('参加中です',
                      style: TextStyle(
                          color: AppColors.success,
                          fontWeight: FontWeight.w600)),
                ),
                OutlinedButton(
                  onPressed: () => _leave(context, ref),
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
                  child: const Text('辞退する'),
                ),
              ],
            )
          else if (isPending)
            const Text('参加承認待ちです', style: TextStyle(color: AppColors.textMuted))
          else if (isInvited)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('この募集に招待されています',
                    style: TextStyle(
                        color: AppColors.primary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: (isFull || post.isEnded)
                            ? null
                            : () => _respondInvite(context, ref,
                                myParticipation!.participationId, true),
                        child: Text(post.isEnded
                            ? '終了しました'
                            : (isFull ? '締め切り' : '参加する')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _respondInvite(context, ref,
                            myParticipation!.participationId, false),
                        child: const Text('辞退する'),
                      ),
                    ),
                  ],
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: (isFull ||
                            post.isEnded ||
                            actionBusy ||
                            post.visibility == BoardVisibility.inviteOnly)
                        ? null
                        : () => _join(context, ref),
                    child: Text(
                      post.isEnded
                          ? '終了しました'
                          : isFull
                              ? '締め切り'
                              : post.visibility == BoardVisibility.approval
                                  ? '参加を申請する'
                                  : '参加する',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    // 参加ボタンは終了時に無効化されているのに、こちらは
                    // チェックが漏れており終了後も「気になる」を押せていた。
                    onPressed: (post.isEnded || actionBusy)
                        ? null
                        : () => _interest(context, ref),
                    child: Text(post.isEnded ? '終了しました' : '興味あり'),
                  ),
                ),
              ],
            ),
          if (isOrganizer || isJoined) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (post.chatGroupId == null && !isOrganizer)
                    ? null
                    : () => _openParticipantChat(context, ref, post),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: Text(
                    post.chatGroupId != null ? '参加者チャットを開く' : '参加者チャットを作成'),
              ),
            ),
          ],
          if (isOrganizer) ...[
            const SizedBox(height: 24),
            Consumer(builder: (context, ref, _) {
              final pendingAsync =
                  ref.watch(boardPendingRequestsProvider(postId));
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
                                _ParticipantAvatar(
                                    url: p.avatarUrl, nickname: p.nickname),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: Text(p.nickname ?? '名無し',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600))),
                                IconButton(
                                  icon: const Icon(Icons.check_circle,
                                      color: AppColors.primary),
                                  onPressed: () => _approveRequest(
                                      context, ref, p.participationId, true),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.cancel,
                                      color: AppColors.error),
                                  onPressed: () => _approveRequest(
                                      context, ref, p.participationId, false),
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
              const Text('参加者',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              if ((isOrganizer || isJoined) && !post.isEnded)
                TextButton.icon(
                  onPressed: () => _invite(
                      context, ref, post, participantsAsync.value ?? []),
                  icon: const Icon(Icons.person_add_alt, size: 16),
                  label: const Text('招待する', style: TextStyle(fontSize: 13)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          participantsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary)),
            ),
            error: (e, _) => const Text('取得に失敗しました',
                style: TextStyle(color: AppColors.textMuted)),
            data: (participants) {
              final attending = attendingMatchesAsync.value ?? {};
              final joined = participants
                  .where((p) => p.status == BoardParticipationStatus.joined)
                  .toList();
              final interested = participants
                  .where((p) => p.status == BoardParticipationStatus.interested)
                  .toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...joined.map((p) => _ParticipantTile(
                        participation: p,
                        isMatch: attending.contains(p.userId),
                      )),
                  // 「気になる」を押した人が誰かは主催者のみ閲覧可能（プライバシー保護）。
                  // 主催者以外には人数のみを表示する。
                  if (isOrganizer && interested.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('興味あり',
                        style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ...interested.map((p) => _ParticipantTile(
                          participation: p,
                          isMatch: attending.contains(p.userId),
                        )),
                  ] else if (!isOrganizer && post.interestedCount > 0) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.favorite,
                            size: 14, color: Colors.pink),
                        const SizedBox(width: 6),
                        Text('気になる ${post.interestedCount}人',
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 12)),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      );
    }
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13))),
        ],
      ),
    );
  }
}

class _ParticipantTile extends ConsumerWidget {
  final BoardParticipationModel participation;
  final bool isMatch;
  const _ParticipantTile({required this.participation, required this.isMatch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = participation.vehicle;
    return InkWell(
      onTap: () => showUserProfile(context, ref, participation.userId),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _ParticipantAvatar(
                url: participation.avatarUrl, nickname: participation.nickname),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          participation.nickname ?? '名無し',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isMatch) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.favorite,
                            size: 12, color: AppColors.primary),
                      ],
                    ],
                  ),
                  if (vehicle != null)
                    Row(
                      children: [
                        Icon(
                          vehicle.vehicleType == VehicleType.bike
                              ? Icons.motorcycle
                              : Icons.directions_car,
                          size: 12,
                          color: AppColors.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            vehicle.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantAvatar extends StatelessWidget {
  final String? url;
  final String? nickname;
  const _ParticipantAvatar({this.url, this.nickname});

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) {
      return ClipOval(
        child: SignedStorageImage(
          storedReference: url!,
          defaultBucket: 'profile-photos',
          width: 28,
          height: 28,
          fit: BoxFit.cover,
        ),
      );
    }
    return const CircleAvatar(
      radius: 14,
      backgroundColor: AppColors.background,
      child: Icon(Icons.person, size: 14, color: AppColors.textMuted),
    );
  }
}
