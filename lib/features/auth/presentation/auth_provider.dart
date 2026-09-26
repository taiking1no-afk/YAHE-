import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/auth_repository.dart';
import '../../../core/revenuecat/revenuecat_config.dart';
import '../../../core/revenuecat/subscription_sync.dart';
import '../../../core/encounter/encounter_dedupe.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../features/notifications/notification_service.dart';
import '../../../shared/models/user_model.dart';

final authRepositoryProvider =
    Provider<AuthRepository>((ref) => AuthRepository());

final authStateProvider = StreamProvider<AuthState>((ref) {
  final repo = ref.read(authRepositoryProvider);
  return repo.authStateChanges;
});

/// ログインボタン押下中のみ true（初回ロードと分離）
final signInInProgressProvider = StateProvider<bool>((ref) => false);

/// ログイン失敗メッセージ（一時的な表示用）。
/// authNotifierProvider の state は失敗直後に AsyncValue.error → 直後に
/// AsyncValue.data(null) と同一の実行内で連続して上書きされるため、
/// build() 側で ref.watch(authNotifierProvider) を読んでも中間のエラー状態を
/// 観測できない（次の再描画時には既に data(null) になっている）。
/// エラー表示専用にこの独立したプロバイダへ書き込む。
final signInErrorProvider = StateProvider<String?>((ref) => null);

class AuthNotifier extends AsyncNotifier<UserModel?> {
  @override
  Future<UserModel?> build() async {
    // runApp直後はSupabaseの初期化がまだ終わっていない可能性がある
    // （main.dartがrunAppをブロックせずに初期化を開始する構成のため）。
    // ここで完了を待ってから Supabase.instance に触れる。
    await SupabaseConfig.ensureInitialized();

    final repo = ref.read(authRepositoryProvider);

    // OAuth 完了（Deep Link 復帰）時にユーザーを反映
    final subscription = repo.authStateChanges.listen((authState) async {
      if (authState.event == AuthChangeEvent.signedIn ||
          authState.event == AuthChangeEvent.tokenRefreshed) {
        try {
          final user = await repo.fetchCurrentUser();
          if (user != null) {
            state = AsyncValue.data(user);
            ref.read(signInInProgressProvider.notifier).state = false;
            EncounterTestMode.setServerAllowed(user.encounterTestMode);
            NotificationService().saveFcmTokenToSupabase(user.userId);
            // RevenueCat同期はUI表示をブロックしないようバックグラウンドで実行
            unawaited(_syncSubscriptionInBackground(user.userId));
          }
        } catch (e) {
          debugPrint('[AuthNotifier] auth state sync error: $e');
        }
      } else if (authState.event == AuthChangeEvent.signedOut) {
        state = const AsyncValue.data(null);
        ref.read(signInInProgressProvider.notifier).state = false;
      }
    });
    ref.onDispose(subscription.cancel);

    try {
      final user = await repo.fetchCurrentUser().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[AuthNotifier] fetchCurrentUser タイムアウト → 未ログイン扱い');
          return null;
        },
      );
      if (user != null) {
        EncounterTestMode.setServerAllowed(user.encounterTestMode);
        // RevenueCatログイン・サブスク同期は起動のクリティカルパスから外し、
        // ホーム画面表示後にバックグラウンドで実行する（実機起動短縮のため）。
        unawaited(_syncSubscriptionInBackground(user.userId));
      }
      return user;
    } catch (e) {
      debugPrint('[AuthNotifier] fetchCurrentUser エラー: $e');
      return null;
    }
  }

  /// RevenueCatへのログイン・エンタイトルメント同期・ユーザー再取得を行う。
  /// 起動/ログインの表示をブロックしないよう常にバックグラウンドで呼ぶ。
  Future<void> _syncSubscriptionInBackground(String userId) async {
    try {
      await RevenueCatConfig.logIn(userId);
      await SubscriptionSync.syncToSupabase(userId);
      final synced = await ref.read(authRepositoryProvider).fetchCurrentUser();
      if (synced != null) {
        state = AsyncValue.data(synced);
        EncounterTestMode.setServerAllowed(synced.encounterTestMode);
      }
    } catch (e) {
      debugPrint('[AuthNotifier] background subscription sync error: $e');
    }
  }

  Future<void> signInWithGoogle() async {
    ref.read(signInInProgressProvider.notifier).state = true;
    ref.read(signInErrorProvider.notifier).state = null;
    try {
      final repo = ref.read(authRepositoryProvider);
      final user = await repo.signInWithGoogle();
      if (user != null) {
        EncounterTestMode.setServerAllowed(user.encounterTestMode);
        NotificationService().saveFcmTokenToSupabase(user.userId);
        // RevenueCatログイン・サブスク同期をここで await していると、ログアウト直後の
        // 再ログインでRevenueCat側の状態が不安定になった際にログイン処理自体が
        // 永久に完了しない（ローディングのまま固まる）ことがあった。build()と同じく
        // クリティカルパスから外し、バックグラウンドで実行する。
        state = AsyncValue.data(user);
        unawaited(_syncSubscriptionInBackground(user.userId));
      } else {
        state = const AsyncValue.data(null);
      }
    } catch (e, st) {
      debugPrint('[AuthNotifier] Google sign-in error: $e');
      state = AsyncValue.error(e, st);
      state = const AsyncValue.data(null);
      ref.read(signInErrorProvider.notifier).state = 'ログインに失敗しました。もう一度お試しください。';
    } finally {
      ref.read(signInInProgressProvider.notifier).state = false;
    }
  }

  Future<void> signInWithApple() async {
    ref.read(signInInProgressProvider.notifier).state = true;
    ref.read(signInErrorProvider.notifier).state = null;
    try {
      final repo = ref.read(authRepositoryProvider);
      final user = await repo.signInWithApple();
      if (user != null) {
        EncounterTestMode.setServerAllowed(user.encounterTestMode);
        NotificationService().saveFcmTokenToSupabase(user.userId);
        // Google側と同様、RevenueCat同期をクリティカルパスから外す（理由は同上）。
        state = AsyncValue.data(user);
        unawaited(_syncSubscriptionInBackground(user.userId));
      } else {
        state = const AsyncValue.data(null);
      }
    } catch (e, st) {
      debugPrint('[AuthNotifier] Apple sign-in error: $e');
      state = AsyncValue.error(e, st);
      state = const AsyncValue.data(null);
      ref.read(signInErrorProvider.notifier).state = 'ログインに失敗しました。もう一度お試しください。';
    } finally {
      ref.read(signInInProgressProvider.notifier).state = false;
    }
  }

  /// 年齢確認・規約同意を保存し、ユーザー状態を更新する
  Future<void> saveAgeAndConsent({
    required DateTime birthDate,
    required String termsVersion,
  }) async {
    final repo = ref.read(authRepositoryProvider);
    final updated = await repo.saveAgeAndConsent(
      birthDate: birthDate,
      termsVersion: termsVersion,
    );
    if (updated != null) {
      state = AsyncValue.data(updated);
    }
  }

  Future<void> signOut() async {
    final repo = ref.read(authRepositoryProvider);
    await repo.signOut();
    await RevenueCatConfig.logOut();
    state = const AsyncValue.data(null);
  }
}

final authNotifierProvider = AsyncNotifierProvider<AuthNotifier, UserModel?>(
  AuthNotifier.new,
);
