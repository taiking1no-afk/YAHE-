import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';

/// Supabase の AuthException（トークン切れ）発生時にセッションを更新して再実行する
Future<T> withSupabaseRetry<T>(Future<T> Function() fn,
    {int maxRetries = 1}) async {
  for (int attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } on AuthException catch (e) {
      debugPrint('[Supabase] AuthException (attempt $attempt): ${e.message}');
      if (attempt == maxRetries) rethrow;
      try {
        await SupabaseConfig.client.auth.refreshSession();
        debugPrint('[Supabase] セッションを更新しました');
      } catch (refreshErr) {
        debugPrint('[Supabase] セッション更新失敗: $refreshErr');
        rethrow;
      }
    } on PostgrestException catch (e) {
      // JWT expired
      // 以前は `attempt < maxRetries` が2つ目の条件にしか掛かっておらず、
      // 最終試行でPGRST301が発生すると本来のPostgrestExceptionではなく
      // 末尾の汎用StateErrorにすり替わって原因追跡ができなくなっていた。
      final isJwtExpired = e.code == 'PGRST301' || e.message.contains('JWT');
      if (isJwtExpired && attempt < maxRetries) {
        debugPrint('[Supabase] JWT期限切れ → リフレッシュ');
        try {
          await SupabaseConfig.client.auth.refreshSession();
        } catch (_) {
          rethrow;
        }
        continue;
      }
      rethrow;
    }
  }
  throw StateError('withSupabaseRetry: 到達不能コード');
}
