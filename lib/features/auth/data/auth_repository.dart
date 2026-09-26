import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../shared/models/user_model.dart';
import '../../profile/data/user_repository.dart';

class AuthRepository {
  AuthRepository();

  static const redirectUrl = 'jp.nozawataiki.yahe://auth/callback';

  final _client = SupabaseConfig.client;

  // UserModel.fromJson が参照するカラムのみ（fcm_token 等の非公開/未使用カラムを除外）
  static const _userColumns =
      'user_id, auth_id, nickname, area, comment, avatar_url, anonymous_mode, plan, trial_ends_at, gear_plus_trial_used_at, premium_override_plan, premium_override_expires_at, premium_override_source, is_verified, verified_label, is_private, birth_date, terms_agreed_at, is_suspended, passing_target, encounter_test_mode, avatar_focal_x, avatar_focal_y, created_at';

  User? get currentAuthUser => _client.auth.currentUser;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<UserModel?> signInWithGoogle() async {
    await _signInWithOAuth(OAuthProvider.google);
    return _fetchOrCreateUser();
  }

  Future<UserModel?> signInWithApple() async {
    // iOS/macOSではネイティブのSign in with Apple（ASAuthorizationController）を使う。
    // 以前はGoogleと同じWebベースOAuth（SFSafariViewController経由）を使っていたが、
    // App Store審査（Guideline 2.1(a)）でApple IDログイン後にアプリが
    // 読み込み中のまま止まる不具合として指摘・再現された。Web版OAuthのままだと
    // Appleのリダイレクト特性上、完了検知に失敗するケースがあったためネイティブ化する。
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return _signInWithAppleNative();
    }
    await _signInWithOAuth(OAuthProvider.apple);
    return _fetchOrCreateUser();
  }

  Future<UserModel?> _signInWithAppleNative() async {
    if (_client.auth.currentUser != null) return _fetchOrCreateUser();

    final rawNonce = _generateNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null; // ユーザーがキャンセル
      rethrow;
    }

    final idToken = credential.identityToken;
    if (idToken == null) {
      throw Exception('Appleからログイン情報を取得できませんでした。もう一度お試しください。');
    }

    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );

    // 氏名はApple ID連携の初回のみ返される（トークン自体には含まれない）ため、
    // 取得できた場合だけ新規ユーザー作成時のニックネーム候補として渡す。
    final nameParts = [credential.givenName, credential.familyName]
        .whereType<String>()
        .where((s) => s.isNotEmpty);
    final appleName = nameParts.isEmpty ? null : nameParts.join(' ');

    return _fetchOrCreateUser(nicknameOverride: appleName);
  }

  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  Future<void> _signInWithOAuth(OAuthProvider provider) async {
    if (_client.auth.currentUser != null) return;

    await _client.auth.signInWithOAuth(
      provider,
      redirectTo: redirectUrl,
      queryParams: {'apikey': SupabaseConfig.supabaseAnonKey},
      // Apple Guideline 4 対応: 外部Safariではなく SFSafariViewController
      // (inAppWebView) でログイン画面をアプリ内表示する
      authScreenLaunchMode: LaunchMode.inAppWebView,
    );

    await _waitForOAuthSession();
  }

  /// ブラウザ OAuth 完了後、Deep Link でセッションが付くまで待つ
  Future<void> _waitForOAuthSession() async {
    if (_client.auth.currentUser != null) return;

    // ブラウザ側でキャンセルされたことを検知する手段が無いため、キャンセル時は
    // このポーリングがタイムアウトするまでボタンが無効のままになる。以前は
    // 180秒（600回）と長すぎたため、体感の「固まった」時間を減らす目的で短縮。
    for (var i = 0; i < 150; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (_client.auth.currentUser != null) {
        // authScreenLaunchMode: inAppWebView は SFSafariViewController で開くため、
        // ASWebAuthenticationSession と違ってリダイレクト時にOSが自動で閉じてくれない。
        // ログイン成立を検知した時点で明示的に閉じ、ユーザーが×ボタンを押す手間をなくす。
        try {
          await closeInAppWebView();
        } catch (_) {}
        return;
      }
    }
    throw Exception('ログインがタイムアウトしました。もう一度お試しください。');
  }

  Future<UserModel?> _fetchOrCreateUser({String? nicknameOverride}) async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    final existing = await _client
        .from('users')
        .select(_userColumns)
        .eq('auth_id', authUser.id)
        .maybeSingle();

    if (existing != null) {
      return _withSns(UserModel.fromJson(existing));
    }

    final nickname = nicknameOverride ??
        authUser.userMetadata?['name'] as String? ??
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
          .select(_userColumns)
          .single();

      return _withSns(UserModel.fromJson(created));
    } catch (e) {
      debugPrint('[AuthRepository] insert failed, retrying select: $e');
      final retry = await _client
          .from('users')
          .select(_userColumns)
          .eq('auth_id', authUser.id)
          .maybeSingle();
      if (retry != null) return _withSns(UserModel.fromJson(retry));
      rethrow;
    }
  }

  Future<UserModel?> fetchCurrentUser() async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    // users / user_sns_links / public_sns_links は互いに依存しないため
    // 並列取得し、起動時のクリティカルパスがラウンドトリップ1回分になるようにする。
    final userFuture = _client
        .from('users')
        .select(_userColumns)
        .eq('auth_id', authUser.id)
        .maybeSingle();
    final snsFuture = _fetchOwnSnsLinksRow();
    final publicSnsFuture = _fetchOwnPublicSnsLink();
    final data = await userFuture;
    final (links, snsVisible) = await snsFuture;
    final publicSnsLink = await publicSnsFuture;
    if (data == null) return null;
    return UserModel.fromJson(data).copyWith(
      snsLinks: links,
      snsVisibleToMatches: snsVisible,
      publicSnsLink: publicSnsLink,
    );
  }

  /// 自分のSNSリンク・表示設定を専用テーブル(user_sns_links)から読み込む（本人の行のみRLSで可視）
  Future<(List<SnsLink>, bool)> _fetchOwnSnsLinksRow() async {
    try {
      final row = await _client
          .from('user_sns_links')
          .select('links, visible_to_matches')
          .maybeSingle();
      final list = (row?['links'] as List<dynamic>? ?? []);
      final links = list
          .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
          .toList();
      final visible = row?['visible_to_matches'] as bool? ?? false;
      return (links, visible);
    } catch (_) {
      return (const <SnsLink>[], false);
    }
  }

  /// プロフィールの公開SNSリンクを読み込む（本人の行のみ）
  Future<PublicSnsLink?> _fetchOwnPublicSnsLink() async {
    try {
      final row = await _client
          .from('public_sns_links')
          .select('platform, url, label, is_visible')
          .maybeSingle();
      if (row == null) return null;
      return PublicSnsLink.fromJson(row);
    } catch (_) {
      return null;
    }
  }

  /// 自分のSNSリンク・公開SNSリンクを読み込んでユーザーに反映する
  Future<UserModel> _withSns(UserModel user) async {
    final (links, snsVisible) = await _fetchOwnSnsLinksRow();
    final publicSnsLink = await _fetchOwnPublicSnsLink();
    return user.copyWith(
      snsLinks: links,
      snsVisibleToMatches: snsVisible,
      publicSnsLink: publicSnsLink,
    );
  }

  /// 年齢確認（生年月日）と規約同意を保存する。
  /// 16歳未満は呼び出し前にブロックする想定（age_consent_screen.dart側でチェック）。
  Future<UserModel?> saveAgeAndConsent({
    required DateTime birthDate,
    required String termsVersion,
  }) async {
    final authUser = _client.auth.currentUser;
    // ここでnullを返すと、呼び出し元(_submit)は例外を検知できず「保存に成功した
    // つもりで画面遷移を待つ」→ redirectでage-consentへ差し戻される→送信ボタンが
    // 押しっぱなし状態のまま操作不能になる、というロックが発生していた。
    // セッション切れは明確な例外として呼び出し元に伝える。
    if (authUser == null) {
      throw Exception('セッションが切れています。もう一度ログインしてください。');
    }

    final updated = await _client
        .from('users')
        .update({
          'birth_date':
              birthDate.toIso8601String().split('T').first, // YYYY-MM-DD
          'terms_agreed_at': DateTime.now().toUtc().toIso8601String(),
          'terms_version': termsVersion,
        })
        .eq('auth_id', authUser.id)
        .select(_userColumns)
        .single();

    return _withSns(UserModel.fromJson(updated));
  }

  Future<void> signOut() async {
    // 保持期間ポリシー「FCMトークンは利用中のみ」：ログアウト時に削除する
    // （ベストエフォート。失敗してもサインアウト自体は継続する）。
    try {
      final authUser = _client.auth.currentUser;
      if (authUser != null) {
        final row = await _client
            .from('users')
            .select('user_id')
            .eq('auth_id', authUser.id)
            .maybeSingle();
        final userId = row?['user_id'] as String?;
        if (userId != null) {
          await UserRepository().deleteFcmToken(userId);
        }
      }
    } catch (_) {}
    await _client.auth.signOut();
  }

  /// アカウント削除（ユーザーデータを全削除してログアウト）
  /// App Store / Google Play 審査要件
  /// アカウント削除（Auth（auth.users）も含めて完全削除）
  ///
  /// Supabase Edge Function 側で service_role を使い、呼び出し元（JWT）のユーザーを削除する。
  /// 削除が成功したときだけ signOut する（失敗時に「消えた」と誤認させない）。
  /// 戻り値は「public.users 行の削除まで確認できたか」（verified）。
  /// false の場合も auth 側の削除自体は成功しているが、念のため確認が
  /// 取れなかったことを呼び出し元に伝える。
  Future<bool> deleteAccount() async {
    final res = await _client.functions.invoke('delete-account', body: {});
    final status = res.status;
    final data = res.data;
    final ok = status >= 200 &&
        status < 300 &&
        (data is Map ? data['ok'] == true : true) &&
        !(data is Map && data['error'] != null);
    if (!ok) {
      final msg = data is Map && data['error'] != null
          ? data['error'].toString()
          : 'アカウント削除に失敗しました（HTTP $status）';
      throw Exception(msg);
    }
    await _client.auth.signOut();
    return data is Map ? (data['verified'] as bool? ?? true) : true;
  }
}
