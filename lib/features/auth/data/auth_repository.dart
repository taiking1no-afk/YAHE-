import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../shared/models/user_model.dart';

class AuthRepository {
  AuthRepository();

  static const redirectUrl = 'jp.nozawataiki.yahe://auth/callback';

  final _client = SupabaseConfig.client;

  User? get currentAuthUser => _client.auth.currentUser;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<UserModel?> signInWithGoogle() async {
    await _signInWithOAuth(OAuthProvider.google);
    return _fetchOrCreateUser();
  }

  Future<UserModel?> signInWithApple() async {
    await _signInWithOAuth(OAuthProvider.apple);
    return _fetchOrCreateUser();
  }

  Future<void> _signInWithOAuth(OAuthProvider provider) async {
    if (_client.auth.currentUser != null) return;

    await _client.auth.signInWithOAuth(
      provider,
      redirectTo: redirectUrl,
      queryParams: {'apikey': SupabaseConfig.supabaseAnonKey},
      authScreenLaunchMode: LaunchMode.externalApplication,
    );

    await _waitForOAuthSession();
  }

  /// ブラウザ OAuth 完了後、Deep Link でセッションが付くまで待つ
  Future<void> _waitForOAuthSession() async {
    if (_client.auth.currentUser != null) return;

    for (var i = 0; i < 600; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (_client.auth.currentUser != null) return;
    }
    throw Exception('ログインがタイムアウトしました。もう一度お試しください。');
  }

  Future<UserModel?> _fetchOrCreateUser() async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    final existing = await _client
        .from('users')
        .select()
        .eq('auth_id', authUser.id)
        .maybeSingle();

    if (existing != null) {
      return _withSns(UserModel.fromJson(existing));
    }

    final nickname = authUser.userMetadata?['name'] as String? ??
        authUser.userMetadata?['full_name'] as String? ??
        authUser.email?.split('@').first ??
        'User';

    try {
      final created = await _client
          .from('users')
          .insert({
            'auth_id': authUser.id,
            'nickname': nickname,
          })
          .select()
          .single();

      return _withSns(UserModel.fromJson(created));
    } catch (e) {
      debugPrint('[AuthRepository] insert failed, retrying select: $e');
      final retry = await _client
          .from('users')
          .select()
          .eq('auth_id', authUser.id)
          .maybeSingle();
      if (retry != null) return _withSns(UserModel.fromJson(retry));
      rethrow;
    }
  }

  Future<UserModel?> fetchCurrentUser() async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    final data = await _client
        .from('users')
        .select()
        .eq('auth_id', authUser.id)
        .maybeSingle();

    if (data == null) return null;
    return _withSns(UserModel.fromJson(data));
  }

  /// 自分のSNSリンクを専用テーブル(user_sns_links)から読み込んで反映する
  Future<UserModel> _withSns(UserModel user) async {
    try {
      final row = await _client
          .from('user_sns_links')
          .select('links')
          .eq('user_id', user.userId)
          .maybeSingle();
      final list = (row?['links'] as List<dynamic>? ?? []);
      final links = list
          .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
          .toList();
      return user.copyWith(snsLinks: links);
    } catch (_) {
      return user;
    }
  }

  /// 年齢確認（生年月日）と規約同意を保存する。
  /// 18歳未満は呼び出し前にブロックする想定。
  Future<UserModel?> saveAgeAndConsent({
    required DateTime birthDate,
    required String termsVersion,
  }) async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    final updated = await _client
        .from('users')
        .update({
          'birth_date':
              birthDate.toIso8601String().split('T').first, // YYYY-MM-DD
          'terms_agreed_at': DateTime.now().toUtc().toIso8601String(),
          'terms_version': termsVersion,
        })
        .eq('auth_id', authUser.id)
        .select()
        .single();

    return _withSns(UserModel.fromJson(updated));
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// アカウント削除（ユーザーデータを全削除してログアウト）
  /// App Store / Google Play 審査要件
  /// アカウント削除（Auth（auth.users）も含めて完全削除）
  ///
  /// Supabase Edge Function 側で service_role を使い、呼び出し元（JWT）のユーザーを削除する。
  Future<void> deleteAccount() async {
    await _client.functions.invoke('delete-account', body: {});
    await _client.auth.signOut();
  }
}
