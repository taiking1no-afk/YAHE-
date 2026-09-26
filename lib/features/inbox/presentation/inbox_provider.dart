import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/inbox_repository.dart';
import '../models/app_notification_model.dart';

final inboxRepositoryProvider =
    Provider<InboxRepository>((ref) => InboxRepository());

final appNotificationsProvider =
    FutureProvider.autoDispose<List<AppNotificationModel>>((ref) {
  return ref.watch(inboxRepositoryProvider).fetchNotifications();
});

final unreadInboxCountProvider = FutureProvider.autoDispose<int>((ref) {
  return ref.watch(inboxRepositoryProvider).fetchUnreadCount();
});

/// アプリ起動時に1回だけ生成される、未読バッジ用のRealtime購読。
/// 他の機能（チャット等）はこれを直接複製せず、同じ購読パターンを画面ごとの
/// スコープ付きProviderとして個別に作ること（チャットのメッセージ受信は
/// 別チャンネルで、この未読バッジ用チャンネルとは分ける）。
final inboxRealtimeProvider = Provider<void>((ref) {
  // UserModelは==/hashCodeを実装していないため、.valueをそのまま監視すると
  // トークン更新のたびに別インスタンス扱いされ、このチャンネルが毎回
  // 再購読される。userIdだけをselectして実際のログインユーザー変更時のみ
  // 再購読させる。
  final userId = ref.watch(authNotifierProvider.select((s) => s.value?.userId));
  if (userId == null) return;

  final repo = ref.watch(inboxRepositoryProvider);
  RealtimeChannel? channel;

  channel = repo.subscribeToChanges(userId, () {
    ref.invalidate(unreadInboxCountProvider);
    ref.invalidate(appNotificationsProvider);
  });

  ref.onDispose(() {
    channel?.unsubscribe();
  });
});
