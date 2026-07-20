import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_colors.dart';
import '../../features/ads/banner_ad_widget.dart';
import '../../features/auth/presentation/auth_provider.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/likes/presentation/likes_screen.dart';
import '../../features/match/presentation/match_screen.dart';
import '../../features/profile/presentation/encounter_stats_provider.dart';
import '../../features/profile/presentation/my_car_screen.dart';
import '../../features/profile/presentation/profile_view_screen.dart';
import '../../features/settings/data/privacy_zone_repository.dart';
import '../../features/settings/presentation/privacy_zone_screen.dart';
import '../../features/store/presentation/gear_plus_trial_prompt.dart';
import '../providers/tab_provider.dart';
import 'permission_warning_banner.dart';

class MainScaffold extends ConsumerStatefulWidget {
  final Widget child;
  const MainScaffold({super.key, required this.child});

  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold> with WidgetsBindingObserver {
  static const _promptShownKey = 'privacy_zone_prompt_shown_v1';
  static const _permWarningLastKey = 'permission_warning_last_shown';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybePromptPrivacyZone()
          .then((_) => _maybePromptGearPlusTrial())
          .then((_) => _maybeShowPermissionWarning());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 設定アプリで権限を許可してアプリに戻ってきたタイミングで再チェックしないと、
    // バナー/ダイアログが古い「未許可」判定のまま表示され続けてしまう。
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(permissionStatusProvider);
      _refreshSocialProviders();
      _refreshEncounterStats();
    }
  }

  // いいね・マッチのタブは IndexedStack で常時マウントされたままのため、
  // autoDispose の FutureProvider が自動では再取得されない。
  // タブ切り替え・アプリ復帰のタイミングで明示的に再取得し、反映を早める。
  void _refreshSocialProviders() {
    ref.invalidate(sentLikesProvider);
    ref.invalidate(receivedLikesProvider);
    ref.invalidate(matchesProvider);
  }

  // 今日/累計のヤエー数（encounterStatsProvider）も同じ理由で自動更新されない
  // ため、プロフィールタブへの切り替え・アプリ復帰時に明示的に再取得する。
  void _refreshEncounterStats() {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) return;
    ref.invalidate(encounterStatsProvider(user.userId));
  }

  Future<void> _maybeShowPermissionWarning() async {
    if (!mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastShown = prefs.getInt(_permWarningLastKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      const interval = 3 * 24 * 60 * 60 * 1000; // 3日
      if (now - lastShown < interval) return;

      final status = await checkPermissions();
      if (status.allGranted) return;

      await prefs.setInt(_permWarningLastKey, now);
      if (!mounted) return;

      final missing = status.missingItems;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 24),
              SizedBox(width: 8),
              Expanded(child: Text('設定が不足しています', style: TextStyle(fontSize: 17))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'すれ違いを正しく検知するために、以下の設定が必要です：',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 12),
              ...missing.map((m) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(m.icon, size: 18, color: AppColors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        m.label,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 8),
              if (!status.locationAlways)
                const Text(
                  'iOSの場合：設定 → YAHE → 位置情報 →「常に」に変更してください',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11, height: 1.5),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('あとで', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                openAppSettings();
              },
              child: const Text('設定を開く'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  /// お試し未利用者に1日1回、Gear+ 初月無料を案内。
  Future<void> _maybePromptGearPlusTrial() async {
    if (!mounted) return;
    try {
      await GearPlusTrialPrompt.maybeShow(context, ref);
    } catch (_) {}
  }

  // 初回のみ：愛車ガード（自宅・職場）が未設定なら設定を強く促す。
  // 盗難対策の要であり、自宅周辺での発信を止める唯一の手段。
  Future<void> _maybePromptPrivacyZone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_promptShownKey) == true) return;

      final user = ref.read(authNotifierProvider).value;
      if (user == null) return;

      final zones = await PrivacyZoneRepository().fetchZones(user.userId);
      // 既にゾーンがある人には出さない（以後も出さない）
      if (zones.isNotEmpty) {
        await prefs.setBool(_promptShownKey, true);
        return;
      }

      await prefs.setBool(_promptShownKey, true);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.shield_outlined,
              color: AppColors.primary, size: 36),
          title: const Text('愛車ガードを設定しましょう'),
          content: const Text(
            '自宅や職場の周辺をガードゾーンに登録すると、その範囲では'
            'すれ違いの発信・記録を停止します。\n\n'
            '愛車の保管場所が他のユーザーに知られるのを防ぐ、'
            '最も重要な盗難対策です。今すぐ設定をおすすめします。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('あとで'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PrivacyZoneScreen()),
                );
              },
              child: const Text('今すぐ設定'),
            ),
          ],
        ),
      );
    } catch (_) {
      // 失敗してもアプリ動作には影響させない
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(selectedTabProvider);

    const screens = [
      HomeScreen(),      // 0: YAHE
      LikesScreen(),     // 1: いいね
      MatchScreen(),     // 2: マッチ
      MyCarScreen(),     // 3: マイカー
      ProfileViewScreen(), // 4: プロフィール
    ];

    return Scaffold(
      body: IndexedStack(
        index: currentIndex,
        children: screens,
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BottomBannerAd(),
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border, width: 1)),
            ),
            child: BottomNavigationBar(
              currentIndex: currentIndex,
              onTap: (i) {
                if (i != currentIndex) {
                  // いいね・マッチタブに切り替えたタイミングで最新状態を取り直す
                  if (i == 1 || i == 2) {
                    _refreshSocialProviders();
                  }
                  // プロフィールタブに切り替えたタイミングでヤエー数を取り直す
                  if (i == 4) {
                    _refreshEncounterStats();
                  }
                }
                ref.read(selectedTabProvider.notifier).state = i;
              },
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.swap_horiz),
                  activeIcon: Icon(Icons.swap_horiz),
                  label: 'YAHE',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.favorite_border),
                  activeIcon: Icon(Icons.favorite),
                  label: 'いいね',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.people_outline),
                  activeIcon: Icon(Icons.people),
                  label: 'マッチ',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.directions_car_outlined),
                  activeIcon: Icon(Icons.directions_car),
                  label: 'マイカー',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  activeIcon: Icon(Icons.person),
                  label: 'プロフィール',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
