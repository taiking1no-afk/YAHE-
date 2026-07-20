import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/auth_repository.dart';
import '../../../core/revenuecat/revenuecat_config.dart';
import '../../../core/revenuecat/subscription_sync.dart';
import '../../../core/encounter/encounter_dedupe.dart';
import '../../../features/notifications/notification_service.dart';
import '../../../shared/models/user_model.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository());

final authStateProvider = StreamProvider<AuthState>((ref) {
  final repo = ref.read(authRepositoryProvider);
  return repo.authStateChanges;
});

/// ログインボタン押下中のみ true（初回ロードと分離）
final signInInProgressProvider = StateProvider<bool>((ref) => false);

class AuthNotifier extends AsyncNotifier<UserModel?> {
  @override
  Future<UserModel?> build() async {
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
    try {
      final repo = ref.read(authRepositoryProvider);
      final user = await repo.signInWithGoogle();
      if (user != null) {
        await RevenueCatConfig.logIn(user.userId);
        EncounterTestMode.setServerAllowed(user.encounterTestMode);
        await SubscriptionSync.syncToSupabase(user.userId);
        final synced = await repo.fetchCurrentUser();
        if (synced != null) EncounterTestMode.setServerAllowed(synced.encounterTestMode);
        NotificationService().saveFcmTokenToSupabase(user.userId);
        state = AsyncValue.data(synced ?? user);
      } else {
        state = const AsyncValue.data(null);
      }
    } catch (e, st) {
      debugPrint('[AuthNotifier] Google sign-in error: $e');
      state = AsyncValue.error(e, st);
      state = const AsyncValue.data(null);
    } finally {
      ref.read(signInInProgressProvider.notifier).state = false;
    }
  }

  Future<void> signInWithApple() async {
    ref.read(signInInProgressProvider.notifier).state = true;
    try {
      final repo = ref.read(authRepositoryProvider);
      final user = await repo.signInWithApple();
      if (user != null) {
        await RevenueCatConfig.logIn(user.userId);
        EncounterTestMode.setServerAllowed(user.encounterTestMode);
        await SubscriptionSync.syncToSupabase(user.userId);
        final synced = await repo.fetchCurrentUser();
        if (synced != null) EncounterTestMode.setServerAllowed(synced.encounterTestMode);
        NotificationService().saveFcmTokenToSupabase(user.userId);
        state = AsyncValue.data(synced ?? user);
      } else {
        state = const AsyncValue.data(null);
      }
    } catch (e, st) {
      debugPrint('[AuthNotifier] Apple sign-in error: $e');
      state = AsyncValue.error(e, st);
      state = const AsyncValue.data(null);
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
