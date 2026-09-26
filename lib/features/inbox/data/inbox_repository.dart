import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/supabase/supabase_config.dart';
import '../models/app_notification_model.dart';

class InboxRepository {
  final _client = SupabaseConfig.client;

  Future<List<AppNotificationModel>> fetchNotifications() async {
    final data = await _client
        .from('app_notifications')
        .select()
        .order('created_at', ascending: false)
        .limit(50);
    return (data as List)
        .map((e) => AppNotificationModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<int> fetchUnreadCount() async {
    // 'match' はすれ違い/マッチ通知バッジ側で matches テーブルを直接見て
    // 別途カウントしているため（お知らせ一覧でも表示元を分けて重複を避けている）、
    // ここに含めると同じマッチが二重にカウントされてしまう。除外する。
    final data = await _client
        .from('app_notifications')
        .select('notification_id')
        .eq('is_read', false)
        .neq('type', 'match');
    return (data as List).length;
  }

  Future<void> markAsRead(String notificationId) async {
    await _client.rpc('mark_notification_read', params: {
      'p_notification_id': notificationId,
    });
  }

  /// 未読件数のRealtime購読。app起動時に1回だけ生成される非autoDisposeの
  /// Providerからのみ呼び出し、画面遷移のたびに購読/解除を繰り返さないこと。
  RealtimeChannel subscribeToChanges(String userId, void Function() onChange) {
    return _client
        .channel('app_notifications_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'app_notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}
