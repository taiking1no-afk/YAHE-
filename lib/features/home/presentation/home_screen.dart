import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../shared/providers/global_realtime_providers.dart';
import '../../../shared/providers/tab_provider.dart';
import '../../ble/ble_encounter_service.dart';
import '../../profile/data/user_repository.dart';
import '../../../shared/widgets/ad_grid_helper.dart';
import '../../../shared/widgets/like_limit_upsell_dialog.dart';
import '../../../shared/widgets/limited_profile_sheet.dart';
import '../../../shared/widgets/match_celebration_dialog.dart';
import '../../../shared/widgets/share_encounter_card.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../ads/banner_ad_widget.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../match/data/match_repository.dart';
import '../../match/presentation/match_detail_screen.dart';
import '../../match/presentation/match_screen.dart';
import '../../likes/presentation/likes_screen.dart';
import '../../../shared/widgets/permission_warning_banner.dart';
import '../../vehicle/presentation/vehicle_register_provider.dart';
import '../../store/models/item_model.dart';
import '../../store/presentation/store_screen.dart'
    show myItemsProvider, StoreScreen;
import 'home_provider.dart';
import 'home_layout_provider.dart';
import 'encounter_card.dart';
import 'passing_target_header.dart';
import 'same_model_effect_overlay.dart';

class HomeScreen extends ConsumerStatefulWidget {
  /// 統合タブ（SocialHubScreen）内に埋め込む場合はtrue。
  /// 自前のScaffold/AppBarを出さず、本体コンテンツのみ返す。
  final bool embedded;
  const HomeScreen({super.key, this.embedded = false});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _effectKey = GlobalKey<SameModelEffectOverlayState>();
  Set<String>? _seenSameModelIds;

  void _handleEncountersUpdate(List<dynamic> encounters) {
    final currentIds = encounters
        .where((e) => e.isSameModel == true)
        .map<String>((e) => e.encounterId as String)
        .toSet();

    // 初回ロード時は「新規」扱いせず、既存分として記録するだけ
    if (_seenSameModelIds == null) {
      _seenSameModelIds = currentIds;
      return;
    }

    final isNew = currentIds.difference(_seenSameModelIds!).isNotEmpty;
    _seenSameModelIds = currentIds;
    if (isNew) {
      _effectKey.currentState?.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final encountersAsync = ref.watch(encountersProvider);
    final user = ref.watch(authNotifierProvider).value;
    final layout = ref.watch(homeLayoutProvider);
    final blockedIds =
        ref.watch(blockedUserIdsProvider).value ?? const <String>{};

    ref.listen(encountersProvider, (previous, next) {
      next.whenData(_handleEncountersUpdate);
    });

    final actions = [
      IconButton(
        tooltip: layout == HomeLayout.list ? 'グリッド表示に切り替え' : 'リスト表示に切り替え',
        icon: Icon(layout == HomeLayout.list
            ? Icons.grid_view_rounded
            : Icons.view_agenda_outlined),
        onPressed: () => ref.read(homeLayoutProvider.notifier).toggle(),
      ),
      GestureDetector(
        onLongPress: kDebugMode
            ? () => _showDebugDialog(context, ref, user?.userId)
            : null,
        child: IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(encountersProvider),
        ),
      ),
    ];

    final body = Stack(
      children: [
        Column(
          children: [
            const PermissionWarningBanner(),
            const _InZoneWarningBanner(),
            const _TodayLikeCountBanner(),
            const _ActiveBoostBanner(),
            const PassingTargetHeader(),
            Expanded(
              child: encountersAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
                error: (e, _) => _EmptyState(
                    onRetry: () => ref.invalidate(encountersProvider)),
                data: (encounters) {
                  if (encounters.isEmpty) {
                    return _EmptyState(
                        onRetry: () => ref.invalidate(encountersProvider));
                  }

                  VoidCallback? buildLikeAction(dynamic encounter) {
                    if (user == null) return null;
                    return () async {
                      final result = await ref
                          .read(likeNotifierProvider.notifier)
                          .sendLike(
                            fromUserId: user.userId,
                            toUserId: encounter.otherUserId ?? '',
                            encounterId: encounter.encounterId,
                          );
                      // いいね直後に「いいねした」一覧へ即時反映
                      ref.invalidate(sentLikesProvider);
                      if (!context.mounted) return;
                      if (result['error'] == 'daily_limit_exceeded') {
                        LikeLimitUpsellDialog.show(context,
                            expiresAt: encounter.expiresAt);
                      } else if (result['already_liked'] == true) {
                        // 重複いいねはダイアログを出さない
                      } else if (result['is_matched'] == true) {
                        ref.invalidate(matchesProvider);
                        ref.invalidate(receivedLikesProvider);
                        MatchCelebrationDialog.show(
                          context,
                          onShare: () => _shareMatch(context, ref, encounter),
                          onViewMatch: () {
                            Navigator.pop(context);
                            goToSocialSubTab(ref, 2);
                          },
                        );
                      }
                    };
                  }

                  VoidCallback? buildBoostLikeAction(dynamic encounter) {
                    if (user == null) return null;
                    return () async {
                      final items = ref.read(myItemsProvider).value ?? const [];
                      final hasBoostItem = items.any((i) =>
                          (i.type == ItemType.shibu ||
                              i.type == ItemType.gekiShibu) &&
                          i.quantity > 0);
                      if (!hasBoostItem) {
                        if (context.mounted) {
                          _showNoBoostItemDialog(context);
                        }
                        return;
                      }
                      final result = await ref
                          .read(likeNotifierProvider.notifier)
                          .sendBoostedLike(
                            fromUserId: user.userId,
                            toUserId: encounter.otherUserId ?? '',
                            encounterId: encounter.encounterId,
                          );
                      ref.invalidate(sentLikesProvider);
                      if (!context.mounted) return;
                      if (result['error'] == 'daily_limit_exceeded') {
                        LikeLimitUpsellDialog.show(context,
                            expiresAt: encounter.expiresAt);
                      } else if (result['error'] == 'no_boost_item') {
                        _showNoBoostItemDialog(context);
                      } else if (result['already_liked'] == true) {
                        final boostLabel =
                            result['boost_type'] == 'geki_shibu'
                                ? '激渋！'
                                : '渋！';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('$boostLabelを送りました')),
                        );
                      } else if (result['is_matched'] == true) {
                        ref.invalidate(matchesProvider);
                        ref.invalidate(receivedLikesProvider);
                        MatchCelebrationDialog.show(
                          context,
                          onShare: () => _shareMatch(context, ref, encounter),
                          onViewMatch: () {
                            Navigator.pop(context);
                            goToSocialSubTab(ref, 2);
                          },
                        );
                      } else if (result['success'] == true) {
                        final boostLabel =
                            result['boost_type'] == 'geki_shibu'
                                ? '激渋！'
                                : '渋！';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('$boostLabelを送りました')),
                        );
                      }
                    };
                  }

                  // 初めてのすれ違い・マッチ済みのときだけシェア導線を出す
                  Future<void> Function(BuildContext)? buildShareAction(
                      dynamic encounter) {
                    final isFirstEncounter = encounter.occurrenceNumber == 1;
                    final canShare =
                        isFirstEncounter || encounter.isMatched == true;
                    if (!canShare) return null;
                    return (ctx) => _shareMatch(
                          ctx,
                          ref,
                          encounter,
                          occasionEmoji: isFirstEncounter ? '⚡' : '🎉',
                          occasionTitle:
                              isFirstEncounter ? '初めてのすれ違い！' : 'マッチしました！',
                        );
                  }

                  Future<void> openProfile(dynamic encounter,
                      VoidCallback? likeAction, VoidCallback? boostAction) async {
                    // 相手が退会・停止済みなどで otherUserId が取れない行が
                    // 混ざっていることがある。以前はここで `as String` を使い、
                    // そのようなカードをタップした瞬間にクラッシュしていた。
                    final String? otherUserId = encounter.otherUserId;
                    if (otherUserId == null) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('このユーザーは表示できません')),
                        );
                      }
                      return;
                    }

                    // マッチ済みの相手は、マッチ画面から見るのと同じ詳細プロフィールを表示する
                    if (encounter.isMatched == true && user != null) {
                      final match = await MatchRepository()
                          .fetchMatchByOtherUserId(user.userId, otherUserId);
                      if (match != null && context.mounted) {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    MatchDetailScreen(match: match)));
                        return;
                      }
                    }
                    final isBlockedByOther =
                        await UserRepository().amIBlockedBy(otherUserId);
                    if (!context.mounted) return;
                    LimitedProfileSheet.show(
                      context,
                      vehicle: encounter.otherVehicle,
                      otherVehicles: encounter.otherVehicles,
                      otherUser: encounter.otherUser,
                      iLiked: encounter.iLiked ?? false,
                      isMatched: encounter.isMatched ?? false,
                      onLike: likeAction,
                      onBoostLike: boostAction,
                      otherUserId: otherUserId,
                      currentUserId: user?.userId,
                      isBlocked: blockedIds.contains(otherUserId),
                      isBlockedByOther: isBlockedByOther,
                      onShare: buildShareAction(encounter),
                      onBlocked: () => invalidateAfterBlockChange(ref),
                    );
                  }

                  // 無料ユーザーのみ広告を挿入（課金者は非表示）
                  final showAds = !(user?.isPremium ?? false);

                  if (layout == HomeLayout.grid) {
                    Widget gridCardBuilder(
                        BuildContext context, dynamic encounter) {
                      final likeAction = buildLikeAction(encounter);
                      final boostAction = buildBoostLikeAction(encounter);
                      return GestureDetector(
                        onTap: () =>
                            openProfile(encounter, likeAction, boostAction),
                        child: EncounterGridCard(
                          encounter: encounter,
                          onLike: likeAction,
                          onBoostLike: boostAction,
                          onShare: buildShareAction(encounter),
                        ),
                      );
                    }

                    return RefreshIndicator(
                      color: AppColors.primary,
                      backgroundColor: AppColors.surface,
                      onRefresh: () async => ref.invalidate(encountersProvider),
                      child: showAds
                          ? CustomScrollView(
                              slivers: buildAdInterleavedGridSlivers<dynamic>(
                                items: encounters,
                                itemBuilder: gridCardBuilder,
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: 3 / 4,
                              ),
                              itemCount: encounters.length,
                              itemBuilder: (context, index) =>
                                  gridCardBuilder(context, encounters[index]),
                            ),
                    );
                  }

                  final items =
                      showAds ? _buildItemsWithAds(encounters) : encounters;

                  return RefreshIndicator(
                    color: AppColors.primary,
                    backgroundColor: AppColors.surface,
                    onRefresh: () async => ref.invalidate(encountersProvider),
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        if (item == 'ad') {
                          return const InlineBannerAdCard();
                        }

                        final encounter = item as dynamic;
                        final likeAction = buildLikeAction(encounter);
                        final boostAction = buildBoostLikeAction(encounter);

                        // タップで限定プロフィールシートを表示
                        return GestureDetector(
                          onTap: () =>
                              openProfile(encounter, likeAction, boostAction),
                          child: EncounterCard(
                            encounter: encounter,
                            onLike: likeAction,
                            onBoostLike: boostAction,
                            onShare: buildShareAction(encounter),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        SameModelEffectOverlay(key: _effectKey),
      ],
    );

    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.end, children: actions),
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(showBack: false, actions: actions),
      body: body,
    );
  }

  void _showNoBoostItemDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Text('アイテムを所持していません'),
        content: const Text(
          '渋！/激渋！を購入すると、その相手への「いいね」だけを'
          '目立たせて送れます。ショップで購入してください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const StoreScreen()));
            },
            child: const Text('ショップへ'),
          ),
        ],
      ),
    );
  }

  void _showDebugDialog(BuildContext context, WidgetRef ref, String? myUserId) {
    if (myUserId == null) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Text('テストすれ違いの入れ方'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'あなたの user_id:\n$myUserId',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            const Text(
              'アプリからの手動挿入は、本番セキュリティのため無効です（v1.28）。\n\n'
              '1. 下の「IDをコピー」\n'
              '2. Supabase → SQL Editor\n'
              '3. admin_seed_test_encounters.sql を開き\n'
              '   v_my に貼り付けて Run\n'
              '4. この画面を更新',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: myUserId));
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('user_id をコピーしました')),
                );
              }
            },
            child: const Text('IDをコピー'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareMatch(
    BuildContext context,
    WidgetRef ref,
    dynamic encounter, {
    String occasionEmoji = '🎉',
    String occasionTitle = 'マッチしました！',
  }) async {
    final me = ref.read(authNotifierProvider).value;
    if (me == null) return;
    final myVehicle = await ref.read(myVehicleProvider(me.userId).future);
    if (!context.mounted) return;
    await shareEncounter(
      context: context,
      occasionEmoji: occasionEmoji,
      occasionTitle: occasionTitle,
      myUser: me,
      myVehicle: myVehicle,
      otherUser: encounter.otherUser,
      otherVehicle: encounter.otherVehicle,
    );
  }
}

// ランダム間隔（2〜5件）で広告を挿入するヘルパー
// 固定シードを使うことで、providerの更新等でbuildが再実行されるたびに
// 広告位置が入れ替わってちらつく・スクロール位置が飛ぶのを防ぐ
// （ad_grid_helper.dartの他画面と同じ方針）。
List<dynamic> _buildItemsWithAds(List<dynamic> encounters) {
  final rng = Random(42);
  final items = <dynamic>[];
  int nextAdAt = 2 + rng.nextInt(4); // 最初は2〜5件後
  int count = 0;
  for (final enc in encounters) {
    items.add(enc);
    count++;
    if (count >= nextAdAt) {
      items.add('ad');
      count = 0;
      nextAdAt = 2 + rng.nextInt(4); // 次の広告まで再抽選
    }
  }
  return items;
}

// 無料プランは1日のいいね送信数に上限があることが分かりにくかったため、
// 本日の残り送信可能数をYAHE画面上部に常時表示する（課金者には不要なので非表示）。
// 「すれ違いが検知されない」という問い合わせの原因切り分けが困難だった
// （愛車ガード範囲内かどうかがアプリ上から一切見えなかったため）。
// 範囲内の間はその場で分かるように明示する。
class _InZoneWarningBanner extends StatelessWidget {
  const _InZoneWarningBanner();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: BleEncounterService().inZoneNotifier,
      builder: (context, inZone, _) {
        if (!inZone) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.warning.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(
            children: [
              Icon(Icons.shield_outlined, size: 14, color: AppColors.warning),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  '現在、愛車ガードの範囲内にいるためすれ違い検知を停止中です',
                  style: TextStyle(
                      color: AppColors.warning,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TodayLikeCountBanner extends ConsumerWidget {
  const _TodayLikeCountBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authNotifierProvider).value;
    if (user == null || user.isPremium) return const SizedBox.shrink();

    final count = ref.watch(todayLikeCountProvider).value;
    if (count == null) return const SizedBox.shrink();

    final limit = AppConstants.freeDailyLikeLimit;
    final remaining = (limit - count).clamp(0, limit);
    final isExhausted = remaining == 0;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (isExhausted ? AppColors.error : AppColors.textMuted)
            .withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.favorite_border,
              size: 14,
              color: isExhausted ? AppColors.error : AppColors.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '本日のいいね: $count / $limit'
              '${isExhausted ? '（上限に達しました）' : ''}',
              style: TextStyle(
                  color:
                      isExhausted ? AppColors.error : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ニトロ / スーパーニトロ使用中は、ストア画面に戻らなくても残り時間が
// 分かるようYAHE画面上部に表示する。
class _ActiveBoostBanner extends ConsumerWidget {
  const _ActiveBoostBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(myItemsProvider).value ?? const [];
    final active = items.where((i) =>
        (i.type == ItemType.nitro || i.type == ItemType.superNitro) &&
        i.isActive);
    if (active.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withOpacity(0.3)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          for (final item in active)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.type.emoji, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 4),
                Text(
                  '${item.type.label}使用中（残り${item.remainingLabel}）',
                  style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback? onRetry;
  const _EmptyState({this.onRetry});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
        child: Column(
          children: [
            const Text('🚗', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 20),
            const Text(
              'まだYAHEしてないよ！',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'ドライブしてYAHEしよう 🏍',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'アプリを起動したまま走ると\nすれ違ったYAHEユーザーが\nここに表示されます',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 13, height: 1.7),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              TextButton(
                onPressed: onRetry,
                child: const Text('更新する'),
              ),
            ],
            const SizedBox(height: 32),
            const _SamplePreviewCard(),
          ],
        ),
      ),
    );
  }
}

/// すれ違いが1件も無いときに、実際の表示イメージを示すサンプルカード。
/// 実データではないことが一目で分かるよう「サンプル」バッジを必ず付ける
/// （フェイクの相手データを本物のように見せると別の審査基準に抵触するため）。
class _SamplePreviewCard extends StatelessWidget {
  const _SamplePreviewCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Divider(color: AppColors.border)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('表示イメージ',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            ),
            Expanded(child: Divider(color: AppColors.border)),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    height: 140,
                    decoration: const BoxDecoration(
                      color: AppColors.surface,
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(16)),
                    ),
                    child: const Center(
                      child: Icon(Icons.directions_car,
                          color: AppColors.textMuted, size: 48),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'サンプル',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'サンプルユーザー',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '◯月◯日 ◯◯:◯◯ にすれ違い',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'すれ違うと、相手の愛車と一言コメントがここに表示され、\n気になったら「いいね」を送れます。',
                      style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          height: 1.6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
