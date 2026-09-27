import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_colors.dart';
import '../../features/ads/banner_ad_widget.dart';
import '../../features/auth/presentation/auth_provider.dart';
import '../../features/boards/presentation/board_list_screen.dart';
import '../../features/groups/presentation/group_list_screen.dart';
import '../../features/home/presentation/home_provider.dart';
import '../../features/inbox/presentation/inbox_provider.dart';
import '../../features/likes/data/likes_repository.dart';
import '../../features/likes/presentation/likes_screen.dart';
import '../../features/match/data/match_repository.dart';
import '../../features/match/presentation/match_screen.dart';
import '../../features/profile/presentation/encounter_stats_provider.dart';
import '../../features/profile/presentation/profile_view_screen.dart';
import '../../features/chat/data/chat_prefs_provider.dart';
import '../../features/chat/presentation/chat_thread_list_screen.dart';
import '../../features/settings/data/privacy_zone_repository.dart';
import '../../features/settings/models/privacy_zone.dart';
import '../../features/settings/presentation/privacy_zone_screen.dart';
import '../../features/store/presentation/gear_plus_trial_prompt.dart';
import '../../features/vehicle/presentation/vehicle_register_provider.dart';
import '../providers/global_realtime_providers.dart';
import '../providers/tab_provider.dart';
import 'chat_group_hub_screen.dart';
import 'like_received_dialog.dart';
import 'match_celebration_dialog.dart';
import 'permission_warning_banner.dart';
import 'scrollable_bottom_nav.dart';
import 'share_encounter_card.dart';
import 'social_hub_screen.dart';

class MainScaffold extends ConsumerStatefulWidget {
  final Widget child;
  const MainScaffold({super.key, required this.child});

  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold>
    with WidgetsBindingObserver {
  static const _promptShownKey = 'privacy_zone_prompt_shown_v1';
  static const _permWarningLastKey = 'daily_warning_last_shown';
  static const _permWarningOptOutKey = 'daily_warning_opt_out';

  // 起動直後、下タブ4画面すべてが同時にビルド→通信を発行して重くなっていたため、
  // 一度でも表示したタブだけを実体化する（未訪問タブはプレースホルダーのまま）。
  final Set<int> _visitedTabs = {0};

  // 起動直後のダイアログ判定チェーンで _maybePromptPrivacyZone と
  // _maybeShowPermissionWarning が同じゾーン一覧を2回取得していたため、
  // 同一起動内では使い回す。
  List<PrivacyZone>? _zonesCache;
  Future<List<PrivacyZone>> _fetchZonesCached(String userId) async {
    return _zonesCache ??= await PrivacyZoneRepository().fetchZones(userId);
  }

  final List<Timer> _prewarmTimers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybePromptPrivacyZone()
          .then((_) => _maybePromptGearPlusTrial())
          .then((_) => _maybeShowPermissionWarning())
          .then((_) => _maybeShowCelebrationPopups());
    });
    // 未訪問タブは初回タップ時に実体化するが、それだと初めてタブを開いた
    // 瞬間に読み込み待ちが発生する。起動直後の通信バーストが収まった頃合いを
    // 見て、裏側で1つずつ時間差で温めておくことで、実際にタップする頃には
    // 既に読み込み済みの状態にする。
    for (var i = 1; i < 4; i++) {
      _prewarmTimers.add(Timer(Duration(milliseconds: 1200 * i), () {
        if (!mounted) return;
        setState(() => _visitedTabs.add(i));
      }));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _prewarmTimers) {
      t.cancel();
    }
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
      _maybeShowCelebrationPopups();
    }
  }

  // いいね・マッチのタブは IndexedStack で常時マウントされたままのため、
  // autoDispose の FutureProvider が自動では再取得されない。
  // タブ切り替え・アプリ復帰のタイミングで明示的に再取得し、反映を早める。
  void _refreshSocialProviders() {
    ref.invalidate(sentLikesProvider);
    ref.invalidate(receivedLikesProvider);
    ref.invalidate(matchesProvider);
    // encountersProvider(YAHEタブのすれ違い一覧)がここに含まれていなかったため、
    // バックグラウンドのBLEサービスが非表示中に記録したすれ違いが、
    // アプリ復帰やタブ切替では反映されず手動更新が必要になっていた。
    ref.invalidate(encountersProvider);
  }

  // 個人チャット・グループチャットの未読数 + 自分がオーナーのグループへの
  // 参加申請数を合算（ミュート中の相手/グループは未読分から除外）。
  int? _chatTabBadgeCount(WidgetRef ref) {
    final muted = ref.watch(mutedChatIdsProvider).value ?? {};
    final dmUnread = ref
        .watch(chatThreadListProvider)
        .value
        ?.where((t) => !muted.contains('dm:${t.matchId}'))
        .fold<int>(0, (sum, t) => sum + t.unreadCount);
    final groupUnread = ref
        .watch(groupChatSummariesProvider)
        .value
        ?.where((g) => !muted.contains('group:${g.groupId}'))
        .fold<int>(0, (sum, g) => sum + g.unreadCount);
    final groupPending = ref
        .watch(groupMyOwnedPendingCountsProvider)
        .value
        ?.values
        .fold<int>(0, (sum, c) => sum + c);
    if (dmUnread == null && groupUnread == null && groupPending == null) {
      return null;
    }
    return (dmUnread ?? 0) + (groupUnread ?? 0) + (groupPending ?? 0);
  }

  // 自分が主催する募集への参加申請数（掲示板タブのバッジ）。
  int? _boardTabBadgeCount(WidgetRef ref) {
    final counts = ref.watch(boardMyOrganizedPendingCountsProvider).value;
    if (counts == null) return null;
    return counts.values.fold<int>(0, (sum, c) => sum + c);
  }

  // ライフサイクル遷移(resumed)が短時間に連続すると（設定アプリへの一時退避、
  // 通知許可シートなど）、ダイアログ表示中にこの関数がもう一度呼ばれ、
  // markCelebrated/markSeenが完了する前に同じマッチ/いいねを再度拾って
  // ダイアログが二重に積み上がっていた。1回だけ実行させるガード。
  bool _showingCelebration = false;

  // 未セレブレートのマッチ・未既読のいいねを確認し、あれば1件だけポップアップを出す。
  // push配信やRealtimeには依存せず、タブ切替・アプリ復帰時のポーリングで確実に拾う。
  // マッチのお祝いを優先し、同時に複数のダイアログを積み上げない
  // （いいねの分は次回のタブ切替/復帰でまた拾われる）。
  Future<void> _maybeShowCelebrationPopups() async {
    if (_showingCelebration) return;
    final user = ref.read(authNotifierProvider).value;
    if (user == null) return;

    _showingCelebration = true;
    try {
      try {
        final matches = await ref.read(matchesProvider.future);
        final uncelebrated =
            matches.where((m) => !m.isCelebratedBy(user.userId)).firstOrNull;
        if (uncelebrated != null) {
          if (!mounted) return;
          await MatchCelebrationDialog.show(
            context,
            onShare: () async {
              Navigator.pop(context);
              final myVehicle =
                  await ref.read(myVehicleProvider(user.userId).future);
              if (!mounted) return;
              await shareEncounter(
                context: context,
                occasionEmoji: '🎉',
                occasionIcon: LucideIcons.partyPopper,
                occasionTitle: 'マッチしました！',
                myUser: user,
                myVehicle: myVehicle,
                otherUser: uncelebrated.otherUser,
                otherVehicle: uncelebrated.otherVehicle,
              );
            },
            onViewMatch: () {
              Navigator.pop(context);
              goToSocialSubTab(ref, 2);
            },
          );
          await MatchRepository().markCelebrated(uncelebrated.matchId);
          ref.invalidate(matchesProvider);
          return;
        }
      } catch (_) {}

      try {
        final received = await ref.read(receivedLikesProvider.future);
        final unseen =
            received.where((e) => !e.isMatched && e.seenAt == null).firstOrNull;
        if (unseen != null) {
          if (!mounted) return;
          await LikeReceivedDialog.show(
            context,
            onViewLikes: () {
              Navigator.pop(context);
              goToSocialSubTab(ref, 1);
            },
          );
          await LikesRepository().markSeen(unseen.likeId);
          ref.invalidate(receivedLikesProvider);
        }
      } catch (_) {}
    } finally {
      _showingCelebration = false;
    }
  }

  // 今日/累計のヤエー数（encounterStatsProvider）も同じ理由で自動更新されない
  // ため、プロフィールタブへの切り替え・アプリ復帰時に明示的に再取得する。
  void _refreshEncounterStats() {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) return;
    ref.invalidate(encounterStatsProvider(user.userId));
  }

  // バックグラウンド検知（権限不足）・愛車ガード未設定を1日1回まとめて警告する。
  // 「以降は表示しない」を選ぶと恒久的に出なくなる（_permWarningOptOutKey）。
  Future<void> _maybeShowPermissionWarning() async {
    if (!mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_permWarningOptOutKey) == true) return;

      final lastShown = prefs.getInt(_permWarningLastKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      const interval = 24 * 60 * 60 * 1000; // 1日
      if (now - lastShown < interval) return;

      final status = await checkPermissions();
      final missing = status.missingItems;

      final user = ref.read(authNotifierProvider).value;
      var privacyZoneMissing = false;
      if (user != null) {
        try {
          final zones = await _fetchZonesCached(user.userId);
          privacyZoneMissing = zones.isEmpty;
        } catch (_) {}
      }

      if (missing.isEmpty && !privacyZoneMissing) return;

      await prefs.setInt(_permWarningLastKey, now);
      if (!mounted) return;

      final dontShowAgain = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: AppColors.warning, size: 24),
              SizedBox(width: 8),
              Expanded(
                  child: Text('設定が不足しています', style: TextStyle(fontSize: 17))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (missing.isNotEmpty) ...[
                const Text(
                  'すれ違いを正しく検知するために、以下の設定が必要です：',
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.6),
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
                              style: const TextStyle(
                                  color: AppColors.textPrimary, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 8),
                if (!status.locationAlways)
                  const Text(
                    'iOSの場合：設定 → YAHE → 位置情報 →「常に」に変更してください',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 11, height: 1.5),
                  ),
              ],
              if (privacyZoneMissing) ...[
                if (missing.isNotEmpty) const SizedBox(height: 14),
                const Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 18, color: AppColors.error),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '愛車ガードが未設定です（自宅・職場周辺の発信停止）',
                        style: TextStyle(
                            color: AppColors.textPrimary, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('以降は表示しない',
                  style: TextStyle(color: AppColors.textMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('あとで',
                  style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx, false);
                if (missing.isNotEmpty) {
                  openAppSettings();
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PrivacyZoneScreen()),
                  );
                }
              },
              child: Text(missing.isNotEmpty ? '設定を開く' : '愛車ガードを設定'),
            ),
          ],
        ),
      );

      if (dontShowAgain == true) {
        await prefs.setBool(_permWarningOptOutKey, true);
      }
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

      final zones = await _fetchZonesCached(user.userId);
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
                  MaterialPageRoute(builder: (_) => const PrivacyZoneScreen()),
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

    // 未読バッジ用のRealtime購読をセッション中1回だけ起動する（非autoDispose）。
    ref.watch(inboxRealtimeProvider);
    // YAHE・いいね・マッチ・チャット・グループ・掲示板の各一覧を、タブ切替や
    // 手動更新なしでリアルタイムに反映するための購読。同じくセッション中1回だけ。
    ref.watch(encountersRealtimeProvider);
    ref.watch(matchesRealtimeProvider);
    ref.watch(likesRealtimeProvider);
    ref.watch(chatListRealtimeProvider);
    ref.watch(groupRealtimeProvider);
    ref.watch(boardRealtimeProvider);

    const screens = [
      SocialHubScreen(), // 0: YAHE・いいね・マッチ（まとまり）
      ChatGroupHubScreen(), // 1: チャット・グループ（まとまり）
      BoardListScreen(), // 2: 掲示板
      ProfileViewScreen(), // 3: プロフィール（マイカーは下部から遷移）
    ];
    _visitedTabs.add(currentIndex);

    return Scaffold(
      body: IndexedStack(
        index: currentIndex,
        children: [
          for (var i = 0; i < screens.length; i++)
            _visitedTabs.contains(i) ? screens[i] : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!(ref.watch(authNotifierProvider).value?.isPremium ?? false))
            const BottomBannerAd(),
          SafeArea(
            top: false,
            child: Container(
              decoration: const BoxDecoration(
                border:
                    Border(top: BorderSide(color: AppColors.border, width: 1)),
              ),
              child: ScrollableBottomNav(
                currentIndex: currentIndex,
                onTap: (i) {
                  if (i != currentIndex) {
                    // 各まとまりタブもIndexedStackで常駐するため、切替時に明示的に再取得する
                    if (i == 0) _refreshSocialProviders();
                    if (i == 1) {
                      ref.invalidate(chatThreadListProvider);
                      ref.invalidate(groupsProvider);
                      ref.invalidate(groupChatSummariesProvider);
                    }
                    if (i == 2) ref.invalidate(boardPostsProvider);
                    if (i == 3) _refreshEncounterStats();
                  }
                  ref.read(selectedTabProvider.notifier).state = i;
                },
                items: [
                  ScrollableBottomNavItem(
                    icon: Icons.swap_horiz,
                    activeIcon: Icons.swap_horiz,
                    label: 'YAHE',
                    badgeCount: (ref
                                .watch(receivedLikesProvider)
                                .value
                                ?.where((e) => !e.isMatched && e.seenAt == null)
                                .length ??
                            0) +
                        (ref
                                .watch(matchesProvider)
                                .value
                                ?.where((m) => !m.isCelebratedBy(ref
                                        .watch(authNotifierProvider)
                                        .value
                                        ?.userId ??
                                    ''))
                                .length ??
                            0),
                  ),
                  ScrollableBottomNavItem(
                    icon: Icons.chat_bubble_outline,
                    activeIcon: Icons.chat_bubble,
                    label: 'チャット',
                    badgeCount: _chatTabBadgeCount(ref),
                  ),
                  ScrollableBottomNavItem(
                    icon: Icons.event_note_outlined,
                    activeIcon: Icons.event_note,
                    label: '掲示板',
                    badgeCount: _boardTabBadgeCount(ref),
                  ),
                  const ScrollableBottomNavItem(
                    icon: Icons.person_outline,
                    activeIcon: Icons.person,
                    label: 'プロフィール',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
