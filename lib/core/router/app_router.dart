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

  _AuthChangeNotifier(Ref ref) {
    ref.listen<AsyncValue<dynamic>>(authNotifierProvider, (prev, next) {
      if (next.isLoading) return;
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
            BleEncounterService().start(userId: userId, isPremium: isPremium);
          }
        } else {
          BleEncounterService().stop().catchError((_) {});
        }
      }
    });
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final authChangeNotifier = _AuthChangeNotifier(ref);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: authChangeNotifier,
    redirect: (context, state) async {
      final authState = ref.read(authNotifierProvider);
      final loc = state.matchedLocation;
      final isSplash = loc == '/splash';
      final isAuthRoute = loc == '/auth';
      final isGateRoute = loc == '/age-consent';

      // ロード中はスプラッシュに留まる
      if (authState.isLoading) return isSplash ? null : '/splash';

      final isLoggedIn = authState.value != null;

      // 未ログイン → ログイン画面のみ許可
      if (!isLoggedIn) return isAuthRoute ? null : '/auth';

      // ログイン済み：年齢確認・規約同意が未完 or 停止中はゲートへ
      final user = authState.value;
      final needsGate =
          user != null && (user.isSuspended || !user.hasCompletedGate);
      if (needsGate) return isGateRoute ? null : '/age-consent';

      // ゲート通過済み：入口系ルートにいるならオンボーディング/ホームへ
      if (isGateRoute || isSplash || isAuthRoute) {
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
          GoRoute(path: '/home', builder: (context, state) => const SizedBox.shrink()),
          GoRoute(path: '/match', builder: (context, state) => const SizedBox.shrink()),
          GoRoute(path: '/my-car', builder: (context, state) => const SizedBox.shrink()),
          GoRoute(path: '/settings', builder: (context, state) => const SizedBox.shrink()),
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
  ConsumerState<_VehicleRegisterFlow> createState() => _VehicleRegisterFlowState();
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
