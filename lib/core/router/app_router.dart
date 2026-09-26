import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants/app_colors.dart';
import '../../features/auth/presentation/auth_screen.dart';
import '../../features/auth/presentation/auth_provider.dart';
import '../../features/auth/presentation/age_consent_screen.dart';
import '../../features/ble/ble_encounter_service.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/vehicle/presentation/vehicle_register_step1.dart';
import '../../features/vehicle/presentation/vehicle_register_step2.dart';
import '../../features/vehicle/presentation/vehicle_register_step3.dart';
import '../../shared/widgets/main_scaffold.dart';

// ログイン状態の変化のみを GoRouter に通知する ChangeNotifier。
// ① 初回ロード完了時（ローディング→確定）に必ず通知 → ログイン/未ログインを判定してリダイレクト
// ② ログイン・ログアウト時に通知
// ③ user data の refresh（プロフィール保存など）では通知しない → タブリセット防止
class _AuthChangeNotifier extends ChangeNotifier {
  bool? _prevLoggedIn;
  bool _startupTimedOut = false;
  Timer? _startupTimer;

  /// 起動直後の認証確定待ちがいつまでも終わらない場合のフェイルセーフ。
  /// dart-define未注入などでSupabase初期化が壊れていても、
  /// スプラッシュ画面に無限に留まらせず未ログイン扱いで先に進める。
  bool get startupTimedOut => _startupTimedOut;

  _AuthChangeNotifier(Ref ref) {
    _startupTimer = Timer(const Duration(seconds: 15), () {
      if (_startupTimedOut) return;
      _startupTimedOut = true;
      debugPrint('[Router] 起動認証確認が15秒でタイムアウト → 未ログイン扱いで続行');
      notifyListeners();
    });

    ref.listen<AsyncValue<dynamic>>(authNotifierProvider, (prev, next) {
      if (next.isLoading) return;
      _startupTimer?.cancel();
      final isLoggedIn = next.value != null;
      final wasLoading = prev?.isLoading ?? true;
      if (wasLoading || _prevLoggedIn != isLoggedIn) {
        _prevLoggedIn = isLoggedIn;
        notifyListeners();

        // ログイン時にBLE検知を自動開始、ログアウト時に停止
        if (isLoggedIn) {
          final user = next.value;
          final userId = user?.userId as String?;
          final isPremium = user?.isPremium as bool? ?? false;
          if (userId != null) {
            BleEncounterService()
                .start(userId: userId, isPremium: isPremium)
                .then((started) {
              if (!started) {
                // 権限拒否時は開始完了扱いにしない（バナーで再設定を促す）
                debugPrint('[BLE] start skipped (permissions denied)');
              }
            });
          }
        } else {
          BleEncounterService().stop().catchError((_) {});
        }
      }
    });
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final authChangeNotifier = _AuthChangeNotifier(ref);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: authChangeNotifier,
    // 未知のディープリンク（想定外のURLスキームの断片など）が来ても、既定の
    // 「Page not found.」を出さずスプラッシュへ逃がす（redirectが現在の
    // 認証状態に応じて正しい画面へ流し直す）。
    errorBuilder: (context, state) => const _SplashScreen(),
    redirect: (context, state) async {
      final authState = ref.read(authNotifierProvider);
      final loc = state.matchedLocation;
      final isSplash = loc == '/splash';
      final isAuthRoute = loc == '/auth';
      final isGateRoute = loc == '/age-consent';
      // Google/Apple OAuthのリダイレクト先(jp.nozawataiki.yahe://auth/callback)。
      // iOSではこのURLがSupabaseの内部ディープリンク処理とは別に、Flutterの
      // ルーティングにも渡ってしまい、未定義パスとしてGoRouterの404
      // （"Page not found."）が一瞬表示されてしまう。専用ルートを用意し、
      // 下の「入口系ルート」判定にも含めることで、ログイン確定後は
      // 通常通りホーム/オンボーディングへ流れるようにする。
      final isAuthCallback = loc == '/auth/callback';

      // ロード中はスプラッシュに留まる（15秒経ってもロードが終わらない場合は
      // フェイルセーフとして未ログイン扱いで進める。認証確定後は
      // _AuthChangeNotifier のリスナーが正しい状態へ再度リダイレクトする）
      if (authState.isLoading && !authChangeNotifier.startupTimedOut) {
        return isSplash ? null : '/splash';
      }

      final isLoggedIn = !authState.isLoading && authState.value != null;

      // 未ログイン → ログイン画面のみ許可（OAuthコールバック待ちの間はそのまま留まる）
      if (!isLoggedIn) return (isAuthRoute || isAuthCallback) ? null : '/auth';

      // ログイン済み：年齢確認・規約同意が未完 or 停止中はゲートへ
      final user = authState.value;
      final needsGate =
          user != null && (user.isSuspended || !user.hasCompletedGate);
      if (needsGate) return isGateRoute ? null : '/age-consent';

      // ゲート通過済み：入口系ルートにいるならオンボーディング/ホームへ
      if (isGateRoute || isSplash || isAuthRoute || isAuthCallback) {
        final done = await isOnboardingDone();
        return done ? '/home' : '/onboarding';
      }
      return null;
    },
    routes: [
      // スプラッシュ（ロード中のみ表示）
      GoRoute(
        path: '/splash',
        builder: (context, state) => const _SplashScreen(),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      // Google/Apple OAuthのリダイレクト先。上のredirectが即座に正しい画面へ流すため、
      // ここでは何も表示せずスプラッシュと同じ待機画面を出すだけでよい。
      GoRoute(
        path: '/auth/callback',
        builder: (context, state) => const _SplashScreen(),
      ),
      // 年齢確認・規約同意ゲート（ログイン後・未同意/停止時）
      GoRoute(
        path: '/age-consent',
        builder: (context, state) => const AgeConsentScreen(),
      ),
      // オンボーディング（初回ログイン後のみ）
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => OnboardingScreen(
          onFinish: () => context.go('/home'),
        ),
      ),
      GoRoute(
        path: '/vehicle-register',
        builder: (context, state) => _VehicleRegisterFlow(),
      ),
      ShellRoute(
        builder: (context, state, child) => MainScaffold(child: child),
        routes: [
          GoRoute(
              path: '/home',
              builder: (context, state) => const SizedBox.shrink()),
          GoRoute(
              path: '/match',
              builder: (context, state) => const SizedBox.shrink()),
          GoRoute(
              path: '/my-car',
              builder: (context, state) => const SizedBox.shrink()),
          GoRoute(
              path: '/settings',
              builder: (context, state) => const SizedBox.shrink()),
        ],
      ),
      GoRoute(
        path: '/privacy-zones',
        builder: (context, state) => const SizedBox.shrink(),
      ),
    ],
  );
});

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'YAHE',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 42,
                fontWeight: FontWeight.w900,
                letterSpacing: 8,
              ),
            ),
            SizedBox(height: 24),
            CircularProgressIndicator(
              color: AppColors.primary,
              strokeWidth: 2,
            ),
          ],
        ),
      ),
    );
  }
}

class _VehicleRegisterFlow extends ConsumerStatefulWidget {
  @override
  ConsumerState<_VehicleRegisterFlow> createState() =>
      _VehicleRegisterFlowState();
}

class _VehicleRegisterFlowState extends ConsumerState<_VehicleRegisterFlow> {
  int _step = 1;

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      1 => VehicleRegisterStep1(onNext: () => setState(() => _step = 2)),
      2 => VehicleRegisterStep2(
          onNext: () => setState(() => _step = 3),
          onBack: () => setState(() => _step = 1),
        ),
      3 => VehicleRegisterStep3(
          onBack: () => setState(() => _step = 2),
          onComplete: () => context.go('/home'),
        ),
      _ => const SizedBox.shrink(),
    };
  }
}
