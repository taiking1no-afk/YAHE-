import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  SupabaseConfig._();

  // .env または環境変数から取得する想定。
  // Release ビルドでは外部注入が必須になるように「未注入なら起動時に失敗」させます。

  static const String _missing = '__MISSING_SUPABASE_ENV__';

  // ローカル開発用（Release では使わない）
  static const String _devSupabaseUrl =
      'https://vsulqmnpnylojtxnzbbf.supabase.co';
  static const String _devSupabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZzdWxxbW5wbnlsb2p0eG56YmJmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY4NTg3NzcsImV4cCI6MjA5MjQzNDc3N30.hHv3MzoMwi98cInZDfUTTeXCnUzkAhcSQM07x0wzz18';

  static const String _supabaseUrlInjected = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: _missing,
  );
  static const String _supabaseAnonKeyInjected = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: _missing,
  );

  static String get supabaseUrl => _resolveEnv(
        injected: _supabaseUrlInjected,
        devFallback: _devSupabaseUrl,
        envName: 'SUPABASE_URL',
      );
  static String get supabaseAnonKey => _resolveEnv(
        injected: _supabaseAnonKeyInjected,
        devFallback: _devSupabaseAnonKey,
        envName: 'SUPABASE_ANON_KEY',
      );

  static String _resolveEnv({
    required String injected,
    required String devFallback,
    required String envName,
  }) {
    if (injected != _missing) return injected;
    if (kReleaseMode) {
      throw StateError('$envName は Release ビルド時に dart-define で必ず注入してください。');
    }
    return devFallback;
  }

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  }

  static Future<void>? _readyFuture;

  /// 初期化を1回だけ開始し、以降は同じFutureを返す（何度呼んでも安全）。
  /// main()でrunApp前にブロックする代わりに使う: runApp直後に呼び始め、
  /// Supabaseへ実際にアクセスする側（AuthNotifier等）がこれをawaitすることで、
  /// 「起動直後の白い/ネイティブスプラッシュを長く見せず、自前のスプラッシュ画面
  /// （ローディング中はそのまま表示され続ける）にすぐ差し替える」ことができる。
  static Future<void> ensureInitialized() {
    return _readyFuture ??= initialize();
  }
}
