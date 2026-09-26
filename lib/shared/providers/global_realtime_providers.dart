import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/supabase/supabase_config.dart';
import '../utils/invalidation_throttle.dart';
import '../../features/auth/presentation/auth_provider.dart';
import '../../features/boards/presentation/board_calendar_screen.dart';
import '../../features/boards/presentation/board_detail_screen.dart';
import '../../features/boards/presentation/board_list_screen.dart';
import '../../features/chat/presentation/chat_thread_list_screen.dart';
import '../../features/groups/presentation/group_detail_screen.dart';
import '../../features/groups/presentation/group_list_screen.dart';
import '../../features/home/presentation/home_provider.dart';
import '../../features/likes/presentation/likes_screen.dart';
import '../../features/match/presentation/match_screen.dart';
import '../widgets/user_groups_section.dart';
import '../../features/profile/data/user_repository.dart';
import '../../features/notifications/presentation/notifications_screen.dart';

/// YAHE・チャット・グループ・掲示板の各一覧を、タブ切替や手動更新なしで
/// リアルタイムに更新するための購読群。main_scaffold.dart からアプリ起動中
/// ずっとwatchされ続けることを前提にした非autoDisposeのProviderとして、
/// 機能ごとに個別のチャンネルを持つ（inboxRealtimeProviderと同じ方針）。
/// 各テーブルはRLSが有効なため、フィルタなしで購読しても自分が閲覧可能な
/// 行の変更しか届かない。

final _client = SupabaseConfig.client;

/// ブロック／ブロック解除の直後に呼ぶ。関係するタイムライン系プロバイダを
/// まとめて無効化し、相手の投稿・すれ違い・いいね・マッチ・チャット一覧を
/// 即座に再取得させる（呼び出し箇所が複数あるため共通化）。
void invalidateAfterBlockChange(WidgetRef ref) {
  ref.invalidate(blockedUserIdsProvider);
  ref.invalidate(matchesProvider);
  ref.invalidate(encountersProvider);
  ref.invalidate(sentLikesProvider);
  ref.invalidate(receivedLikesProvider);
  ref.invalidate(boardPostsProvider);
  ref.invalidate(allBoardPostsProvider);
  ref.invalidate(myBoardParticipationProvider);
  ref.invalidate(boardParticipantsProvider);
  // ブロックした相手が主催する募集からの自動辞退・チャット退出、
  // 未参加グループの非表示に伴い、グループ側の一覧・チャット一覧も更新する。
  ref.invalidate(groupsProvider);
  ref.invalidate(myGroupsProvider);
  ref.invalidate(groupChatSummariesProvider);
  // 個人チャット一覧にブロック除外フィルタが元々無く、かつここでも
  // invalidateしていなかったため、ブロック後もチャット一覧に相手が残り
  // 続け、再入室できてしまっていた。
  ref.invalidate(chatThreadListProvider);
}

final encountersRealtimeProvider = Provider<void>((ref) {
  // UserModelは==/hashCodeを実装していないため、ref.watch(authNotifierProvider).value
  // をそのまま使うと、トークン更新のたび（約1時間毎など内容が同一でも）新しい
  // インスタンスとして「変化した」扱いになり、この購読が毎回unsubscribe→subscribe
  // し直されていた（再購読の隙間でイベントを取りこぼす）。userIdだけをselectし、
  // 実際にログインユーザーが変わったときだけ再購読させる。
  final userId = ref.watch(authNotifierProvider.select((s) => s.value?.userId));
  if (userId == null) return;

  final channel = _client
      .channel('rt_encounters_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'encounters',
        callback: (_) {
          ref.invalidate(encountersProvider);
          // すれ違いもapp_notificationsを経由しないため、matches同様に
          // 明示的に無効化しないとベルの未読件数がリアルタイムに反映されない。
          ref.invalidate(unreadNotifCountProvider);
        },
      )
      .subscribe();

  ref.onDispose(() => channel.unsubscribe());
});

final matchesRealtimeProvider = Provider<void>((ref) {
  // UserModelは==/hashCodeを実装していないため、ref.watch(authNotifierProvider).value
  // をそのまま使うと、トークン更新のたび（約1時間毎など内容が同一でも）新しい
  // インスタンスとして「変化した」扱いになり、この購読が毎回unsubscribe→subscribe
  // し直されていた（再購読の隙間でイベントを取りこぼす）。userIdだけをselectし、
  // 実際にログインユーザーが変わったときだけ再購読させる。
  final userId = ref.watch(authNotifierProvider.select((s) => s.value?.userId));
  if (userId == null) return;

  final channel = _client
      .channel('rt_matches_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'matches',
        callback: (_) {
          ref.invalidate(matchesProvider);
          // send_like()はマッチ成立時にapp_notificationsへ行を作らず
          // matchesテーブルへの書き込みのみで完結する設計のため、
          // お知らせベルの未読件数(unreadNotifCountProvider)はここで
          // 明示的に無効化しないと、新しいマッチが来てもお知らせ画面を
          // 開くまでバッジが更新されなかった。
          ref.invalidate(unreadNotifCountProvider);
        },
      )
      .subscribe();

  ref.onDispose(() => channel.unsubscribe());
});

final likesRealtimeProvider = Provider<void>((ref) {
  // UserModelは==/hashCodeを実装していないため、ref.watch(authNotifierProvider).value
  // をそのまま使うと、トークン更新のたび（約1時間毎など内容が同一でも）新しい
  // インスタンスとして「変化した」扱いになり、この購読が毎回unsubscribe→subscribe
  // し直されていた（再購読の隙間でイベントを取りこぼす）。userIdだけをselectし、
  // 実際にログインユーザーが変わったときだけ再購読させる。
  final userId = ref.watch(authNotifierProvider.select((s) => s.value?.userId));
  if (userId == null) return;

  final channel = _client
      .channel('rt_likes_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'likes',
        callback: (_) {
          ref.invalidate(sentLikesProvider);
          ref.invalidate(receivedLikesProvider);
        },
      )
      .subscribe();

  ref.onDispose(() => channel.unsubscribe());
});

final chatListRealtimeProvider = Provider<void>((ref) {
  // UserModelは==/hashCodeを実装していないため、ref.watch(authNotifierProvider).value
  // をそのまま使うと、トークン更新のたび（約1時間毎など内容が同一でも）新しい
  // インスタンスとして「変化した」扱いになり、この購読が毎回unsubscribe→subscribe
  // し直されていた（再購読の隙間でイベントを取りこぼす）。userIdだけをselectし、
  // 実際にログインユーザーが変わったときだけ再購読させる。
  final userId = ref.watch(authNotifierProvider.select((s) => s.value?.userId));
  if (userId == null) return;

  final channel = _client
      .channel('rt_chat_list_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_messages',
        callback: (_) => ref.invalidate(chatThreadListProvider),
      )
      .subscribe();

  ref.onDispose(() => channel.unsubscribe());
});

final groupRealtimeProvider = Provider<void>((ref) {
  // UserModelは==/hashCodeを実装していないため、ref.watch(authNotifierProvider).value
  // をそのまま使うと、トークン更新のたび（約1時間毎など内容が同一でも）新しい
  // インスタンスとして「変化した」扱いになり、この購読が毎回unsubscribe→subscribe
  // し直されていた（再購読の隙間でイベントを取りこぼす）。userIdだけをselectし、
  // 実際にログインユーザーが変わったときだけ再購読させる。
  final userId = ref.watch(authNotifierProvider.select((s) => s.value?.userId));
  if (userId == null) return;

  // 大人数が短時間に参加・脱退等を行うと変更イベントが連続で届き、
  // そのたびに画面が再構築されて「チカチカ」して見えるため間引く。
  // 定員などのサーバー側の整合性はRPC側のロックで別途担保されているので、
  // ここでの間引きは表示の更新頻度だけに影響する。
  final membershipThrottle = InvalidationThrottle();
  final messageThrottle = InvalidationThrottle();
  final groupsThrottle = InvalidationThrottle();
  ref.onDispose(() {
    membershipThrottle.dispose();
    messageThrottle.dispose();
    groupsThrottle.dispose();
  });

  final channel = _client
      .channel('rt_groups_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'group_memberships',
        callback: (_) => membershipThrottle.trigger(() {
          ref.invalidate(groupsProvider);
          ref.invalidate(myInvitedGroupsProvider);
          ref.invalidate(groupChatSummariesProvider);
          ref.invalidate(groupMembersProvider);
          ref.invalidate(groupPendingRequestsProvider);
          ref.invalidate(myGroupMembershipProvider);
          ref.invalidate(myGroupsProvider);
          ref.invalidate(groupMyOwnedPendingCountsProvider);
        }),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'group_messages',
        callback: (_) => messageThrottle
            .trigger(() => ref.invalidate(groupChatSummariesProvider)),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'groups',
        callback: (_) => groupsThrottle.trigger(() {
          ref.invalidate(groupsProvider);
          ref.invalidate(groupDetailProvider);
          ref.invalidate(myGroupsProvider);
        }),
      )
      .subscribe();

  ref.onDispose(() => channel.unsubscribe());
});

final boardRealtimeProvider = Provider<void>((ref) {
  // UserModelは==/hashCodeを実装していないため、ref.watch(authNotifierProvider).value
  // をそのまま使うと、トークン更新のたび（約1時間毎など内容が同一でも）新しい
  // インスタンスとして「変化した」扱いになり、この購読が毎回unsubscribe→subscribe
  // し直されていた（再購読の隙間でイベントを取りこぼす）。userIdだけをselectし、
  // 実際にログインユーザーが変わったときだけ再購読させる。
  final userId = ref.watch(authNotifierProvider.select((s) => s.value?.userId));
  if (userId == null) return;

  // groupRealtimeProvider と同じ理由でスロットルする
  // （参加・気になる等が一斉に行われるとイベントが連続で届くため）。
  final postsThrottle = InvalidationThrottle();
  final participationsThrottle = InvalidationThrottle();
  ref.onDispose(() {
    postsThrottle.dispose();
    participationsThrottle.dispose();
  });

  final channel = _client
      .channel('rt_boards_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'board_posts',
        callback: (_) => postsThrottle.trigger(() {
          ref.invalidate(boardPostsProvider);
          ref.invalidate(allBoardPostsProvider);
          ref.invalidate(boardPostDetailProvider);
        }),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'board_participations',
        callback: (_) => participationsThrottle.trigger(() {
          ref.invalidate(boardPostsProvider);
          ref.invalidate(allBoardPostsProvider);
          ref.invalidate(boardParticipantsProvider);
          ref.invalidate(myBoardParticipationProvider);
          ref.invalidate(boardPendingRequestsProvider);
          ref.invalidate(boardMyOrganizedPendingCountsProvider);
        }),
      )
      .subscribe();

  ref.onDispose(() => channel.unsubscribe());
});
