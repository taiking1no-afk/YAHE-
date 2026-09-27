import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/providers/global_realtime_providers.dart';
import '../../../shared/providers/list_grid_layout_provider.dart';
import '../../../shared/providers/tab_provider.dart';
import '../../../shared/widgets/ad_grid_helper.dart';
import '../../../shared/widgets/like_limit_upsell_dialog.dart';
import '../../../shared/widgets/limited_profile_sheet.dart';
import '../../../shared/widgets/match_celebration_dialog.dart';
import '../../../shared/widgets/public_badge.dart';
import '../../../shared/widgets/sample_timeline_preview.dart';
import '../../../shared/widgets/share_encounter_card.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../ads/banner_ad_widget.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../home/data/encounter_repository.dart';
import '../../home/presentation/encounter_card.dart' show BoostBadge;
import '../../home/presentation/home_provider.dart';
import '../../match/presentation/match_screen.dart';
import '../../profile/data/user_repository.dart';
import '../../vehicle/models/vehicle.dart';
import '../../vehicle/presentation/vehicle_register_provider.dart';
import '../data/likes_repository.dart';
import '../models/like_entry.dart';

const _likesLayoutKey = 'likes';

final _likesRepoProvider =
    Provider<LikesRepository>((ref) => LikesRepository());
final _encounterRepoProvider =
    Provider<EncounterRepository>((ref) => EncounterRepository());

final sentLikesProvider =
    FutureProvider.autoDispose<List<LikeEntry>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];
  return ref.read(_likesRepoProvider).fetchSentLikes(user.userId);
});

final receivedLikesProvider =
    FutureProvider.autoDispose<List<LikeEntry>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];
  return ref.read(_likesRepoProvider).fetchReceivedLikes(user.userId);
});

class LikesScreen extends ConsumerStatefulWidget {
  /// 統合タブ（SocialHubScreen）内に埋め込む場合はtrue。
  final bool embedded;
  const LikesScreen({super.key, this.embedded = false});

  @override
  ConsumerState<LikesScreen> createState() => _LikesScreenState();
}

class _LikesScreenState extends ConsumerState<LikesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(listGridLayoutProvider(_likesLayoutKey));

    final actions = [
      IconButton(
        tooltip: layout == ListGridLayout.list ? 'グリッド表示に切り替え' : 'リスト表示に切り替え',
        icon: Icon(layout == ListGridLayout.list
            ? Icons.grid_view_rounded
            : Icons.view_agenda_outlined),
        onPressed: () =>
            ref.read(listGridLayoutProvider(_likesLayoutKey).notifier).toggle(),
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        onPressed: () {
          ref.invalidate(sentLikesProvider);
          ref.invalidate(receivedLikesProvider);
        },
      ),
    ];

    final body = Column(
      children: [
        // タブバー
        Container(
          color: AppColors.surface,
          child: TabBar(
            controller: _tabController,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textMuted,
            indicatorColor: AppColors.primary,
            dividerColor: AppColors.border,
            tabs: [
              _TabWithBadge(label: 'いいねした', provider: sentLikesProvider),
              _TabWithBadge(
                  label: 'いいねされた',
                  provider: receivedLikesProvider,
                  highlight: true),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              // いいねした相手
              _SentLikesList(),
              // いいねされた相手（いいね返しでマッチ）
              _ReceivedLikesList(),
            ],
          ),
        ),
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
      appBar: YaheAppBar(title: 'いいね', showBack: false, actions: actions),
      body: body,
    );
  }
}

// ─── タブ（バッジ付き） ──────────────────────────────────────
class _TabWithBadge extends ConsumerWidget {
  final String label;
  final ProviderBase<AsyncValue<List<LikeEntry>>> provider;
  final bool highlight;

  const _TabWithBadge(
      {required this.label, required this.provider, this.highlight = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(provider).value?.length ?? 0;
    return Tab(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: highlight ? AppColors.primary : AppColors.textMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── いいねした相手リスト ────────────────────────────────────
class _SentLikesList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sentLikesProvider);
    final layout = ref.watch(listGridLayoutProvider(_likesLayoutKey));
    final showAds =
        !(ref.watch(authNotifierProvider).value?.isPremium ?? false);
    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: () async => ref.invalidate(sentLikesProvider),
      child: async.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (_, __) => const Center(child: Text('読み込みに失敗しました')),
      data: (entries) {
        if (entries.isEmpty) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.favorite_border,
                    size: 56, color: AppColors.textMuted),
                const SizedBox(height: 12),
                const Text('まだいいねしていません',
                    style: TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                const Text('YAHEタブから気になる車にいいねしよう',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                const SizedBox(height: 32),
                const SampleTimelinePreview(
                  sampleName: 'サンプルユーザー',
                  sampleSubtitle: 'いいね日: ◯月◯日',
                  description: 'いいねした相手はここに表示されます。相互にいいねするとマッチが成立します。',
                ),
              ],
            ),
          );
        }

        Widget gridCard(BuildContext context, LikeEntry entry) =>
            _LikeEntryGridCard(
              entry: entry,
              canLikeBack: false,
              showCancel: !entry.isMatched,
            );

        if (layout == ListGridLayout.grid) {
          if (showAds) {
            return CustomScrollView(
              slivers: buildAdInterleavedGridSlivers<LikeEntry>(
                items: entries,
                itemBuilder: gridCard,
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 3 / 4,
            ),
            itemCount: entries.length,
            itemBuilder: (context, i) => gridCard(context, entries[i]),
          );
        }

        if (showAds) {
          final items = interleaveItemsWithAds<LikeEntry>(entries);
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item == 'ad') return const InlineBannerAdCard();
              return _LikeEntryTile(
                  entry: item as LikeEntry, canLikeBack: false);
            },
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: entries.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: AppColors.border, indent: 72),
          itemBuilder: (context, i) => _LikeEntryTile(
            entry: entries[i],
            canLikeBack: false,
          ),
        );
      },
      ),
    );
  }
}

// ─── いいねされた相手リスト ─────────────────────────────────
class _ReceivedLikesList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(receivedLikesProvider);
    final user = ref.watch(authNotifierProvider).value;
    final layout = ref.watch(listGridLayoutProvider(_likesLayoutKey));
    final showAds = !(user?.isPremium ?? false);

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: () async => ref.invalidate(receivedLikesProvider),
      child: async.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (_, __) => const Center(child: Text('読み込みに失敗しました')),
      data: (entries) {
        if (entries.isEmpty) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.favorite,
                    size: 56, color: AppColors.textMuted),
                const SizedBox(height: 12),
                const Text('まだいいねされていません',
                    style: TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                const Text('ドライブしてYAHEしよう！',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                const SizedBox(height: 32),
                const SampleTimelinePreview(
                  sampleName: 'サンプルユーザー',
                  sampleSubtitle: 'いいね日: ◯月◯日',
                  description: 'いいねしてくれた相手はここに表示されます。いいねを返すとマッチが成立します。',
                ),
              ],
            ),
          );
        }

        VoidCallback? buildLikeBack(LikeEntry entry) {
          if (user == null) return null;
          return () async {
            final repo = ref.read(_encounterRepoProvider);
            try {
              final encounterId = entry.encounterId;
              final result = encounterId != null
                  ? await repo.sendLike(
                      fromUserId: user.userId,
                      toUserId: entry.otherUserId,
                      encounterId: encounterId,
                    )
                  : await repo.sendLikeNoEncounter(
                      fromUserId: user.userId,
                      toUserId: entry.otherUserId,
                    );
              ref.invalidate(receivedLikesProvider);
              ref.invalidate(sentLikesProvider);
              ref.invalidate(todayLikeCountProvider);
              if (result['success'] != true) {
                if (context.mounted) {
                  if (result['error'] == 'daily_limit_exceeded') {
                    LikeLimitUpsellDialog.show(context);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content:
                            Text('いいねに失敗しました: ${result['error'] ?? 'unknown'}'),
                      ),
                    );
                  }
                }
                return;
              }
              if (result['is_matched'] == true) {
                ref.invalidate(matchesProvider);
                if (context.mounted) {
                  MatchCelebrationDialog.show(
                    context,
                    onShare: () => _shareMatch(context, ref, entry),
                    onViewMatch: () {
                      Navigator.pop(context);
                      goToSocialSubTab(ref, 2);
                    },
                  );
                }
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('いいねに失敗しました: $e')),
                );
              }
            }
          };
        }

        Widget gridCard(BuildContext context, LikeEntry entry) =>
            _LikeEntryGridCard(
              entry: entry,
              canLikeBack: !entry.isMatched,
              onLikeBack: buildLikeBack(entry),
            );

        if (layout == ListGridLayout.grid) {
          if (showAds) {
            return CustomScrollView(
              slivers: buildAdInterleavedGridSlivers<LikeEntry>(
                items: entries,
                itemBuilder: gridCard,
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 3 / 4,
            ),
            itemCount: entries.length,
            itemBuilder: (context, i) => gridCard(context, entries[i]),
          );
        }

        if (showAds) {
          final items = interleaveItemsWithAds<LikeEntry>(entries);
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item == 'ad') return const InlineBannerAdCard();
              final entry = item as LikeEntry;
              return _LikeEntryTile(
                entry: entry,
                canLikeBack: !entry.isMatched,
                onLikeBack: buildLikeBack(entry),
              );
            },
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: entries.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: AppColors.border, indent: 72),
          itemBuilder: (context, i) => _LikeEntryTile(
            entry: entries[i],
            canLikeBack: !entries[i].isMatched,
            onLikeBack: buildLikeBack(entries[i]),
          ),
        );
      },
      ),
    );
  }

  Future<void> _shareMatch(
          BuildContext context, WidgetRef ref, LikeEntry entry) =>
      _shareLikeEntryMatch(context, ref, entry);
}

// マッチ済みの相手をSNSでシェアする（いいね一覧のカードから開いた詳細シート用）
Future<void> _shareLikeEntryMatch(
    BuildContext context, WidgetRef ref, LikeEntry entry) async {
  final me = ref.read(authNotifierProvider).value;
  if (me == null) return;
  final myVehicle = await ref.read(myVehicleProvider(me.userId).future);
  if (!context.mounted) return;
  await shareEncounter(
    context: context,
    occasionEmoji: '🎉',
    occasionIcon: LucideIcons.partyPopper,
    occasionTitle: 'マッチしました！',
    myUser: me,
    myVehicle: myVehicle,
    otherUser: entry.otherUser,
    otherVehicle: entry.otherVehicle,
  );
}

// ─── いいねエントリーカード ──────────────────────────────────
class _LikeEntryTile extends ConsumerWidget {
  final LikeEntry entry;
  final bool canLikeBack;
  final VoidCallback? onLikeBack;

  const _LikeEntryTile(
      {required this.entry, required this.canLikeBack, this.onLikeBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicles = entry.otherVehicles;
    final primaryVehicle = entry.otherVehicle;
    final user = entry.otherUser;
    final timeStr = DateFormat('M月d日 HH:mm').format(entry.createdAt);
    final currentUser = ref.watch(authNotifierProvider).value;
    final blockedIds =
        ref.watch(blockedUserIdsProvider).value ?? const <String>{};

    return GestureDetector(
      onTap: () async {
        UserRepository().recordProfileView(entry.otherUserId);
        final isBlockedByOther =
            await UserRepository().amIBlockedBy(entry.otherUserId);
        if (!context.mounted) return;
        LimitedProfileSheet.show(
          context,
          vehicle: primaryVehicle,
          otherVehicles: vehicles,
          otherUser: user,
          otherUserId: entry.otherUserId,
          currentUserId: currentUser?.userId,
          iLiked: !canLikeBack,
          isMatched: entry.isMatched,
          isBlocked: blockedIds.contains(entry.otherUserId),
          isBlockedByOther: isBlockedByOther,
          onLike: canLikeBack ? onLikeBack : null,
          onShare: entry.isMatched
              ? (ctx) => _shareLikeEntryMatch(ctx, ref, entry)
              : null,
          onBlocked: () => invalidateAfterBlockChange(ref),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: entry.isMatched ? AppColors.primary : AppColors.border,
            width: entry.isMatched ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // メイン写真
            if (primaryVehicle?.photos.isNotEmpty == true)
              ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: SignedStorageImage(
                  storedReference: primaryVehicle!.photos.first,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              )
            else
              ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: Container(
                  height: 100,
                  color: AppColors.surface,
                  child: const Center(
                      child: Icon(Icons.directions_car,
                          color: AppColors.textMuted, size: 40)),
                ),
              ),

            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ニックネーム + アクションボタン
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (user != null)
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      user.nickname,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (!user.isPrivate) ...[
                                    const SizedBox(width: 6),
                                    const PublicBadge(),
                                  ],
                                ],
                              ),
                            if (entry.boostType != null) ...[
                              const SizedBox(height: 4),
                              BoostBadge(
                                icon: entry.boostType == 'geki_shibu'
                                    ? LucideIcons.star
                                    : LucideIcons.flame,
                                label: entry.boostType == 'geki_shibu'
                                    ? '激渋！'
                                    : '渋！',
                              ),
                            ],
                            if (user?.comment != null &&
                                user!.comment!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                '"${user.comment!}"',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 4),
                            Text(
                              timeStr,
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (entry.isMatched)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.primary),
                          ),
                          child: const Text('MATCH',
                              style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1)),
                        )
                      else if (canLikeBack)
                        ElevatedButton.icon(
                          onPressed: onLikeBack,
                          icon: const Icon(Icons.favorite_border, size: 16),
                          label: const Text('いいね'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(80, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                        )
                      else
                        _CancelLikeButton(
                          onCancel: () =>
                              _confirmAndCancelLike(context, ref, entry),
                        ),
                    ],
                  ),

                  // 愛車一覧
                  if (vehicles.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Divider(height: 1, color: AppColors.border),
                    const SizedBox(height: 8),
                    ...vehicles.map((v) => _VehicleRow(vehicle: v)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── いいねエントリーカード（グリッド表示用） ─────────────────
class _LikeEntryGridCard extends ConsumerWidget {
  final LikeEntry entry;
  final bool canLikeBack;
  final VoidCallback? onLikeBack;
  final bool showCancel;

  const _LikeEntryGridCard({
    required this.entry,
    required this.canLikeBack,
    this.onLikeBack,
    this.showCancel = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primaryVehicle = entry.otherVehicle;
    final user = entry.otherUser;
    final currentUser = ref.watch(authNotifierProvider).value;
    final blockedIds =
        ref.watch(blockedUserIdsProvider).value ?? const <String>{};

    return GestureDetector(
      onTap: () async {
        UserRepository().recordProfileView(entry.otherUserId);
        final isBlockedByOther =
            await UserRepository().amIBlockedBy(entry.otherUserId);
        if (!context.mounted) return;
        LimitedProfileSheet.show(
          context,
          vehicle: primaryVehicle,
          otherVehicles: entry.otherVehicles,
          otherUser: user,
          otherUserId: entry.otherUserId,
          currentUserId: currentUser?.userId,
          iLiked: !canLikeBack,
          isMatched: entry.isMatched,
          isBlocked: blockedIds.contains(entry.otherUserId),
          isBlockedByOther: isBlockedByOther,
          onLike: canLikeBack ? onLikeBack : null,
          onShare: entry.isMatched
              ? (ctx) => _shareLikeEntryMatch(ctx, ref, entry)
              : null,
          onBlocked: () => invalidateAfterBlockChange(ref),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: entry.isMatched ? AppColors.primary : AppColors.border,
              width: entry.isMatched ? 1.5 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (primaryVehicle?.photos.isNotEmpty == true)
                  SignedStorageImage(
                    storedReference: primaryVehicle!.photos.first,
                    fit: BoxFit.cover,
                    placeholder: Container(color: AppColors.surface),
                  )
                else
                  Container(
                    color: AppColors.surface,
                    child: const Center(
                        child: Icon(Icons.directions_car,
                            color: AppColors.textMuted, size: 40)),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (user != null)
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  user.nickname,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (!user.isPrivate) ...[
                                const SizedBox(width: 4),
                                const PublicBadge(),
                              ],
                            ],
                          ),
                        if (primaryVehicle != null)
                          Text(
                            primaryVehicle.displayName,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ),
                if (entry.boostType != null)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: BoostBadge(
                      icon: entry.boostType == 'geki_shibu'
                          ? LucideIcons.star
                          : LucideIcons.flame,
                      label: entry.boostType == 'geki_shibu' ? '激渋！' : '渋！',
                    ),
                  ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: entry.isMatched
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text('MATCH',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800)),
                        )
                      : canLikeBack
                          ? GestureDetector(
                              onTap: onLikeBack,
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: const BoxDecoration(
                                    color: Colors.black45,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.favorite_border,
                                    color: Colors.white, size: 16),
                              ),
                            )
                          : showCancel
                              ? GestureDetector(
                                  onTap: () => _confirmAndCancelLike(
                                      context, ref, entry),
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: const BoxDecoration(
                                        color: Colors.black45,
                                        shape: BoxShape.circle),
                                    child: const Icon(Icons.close,
                                        color: Colors.white, size: 16),
                                  ),
                                )
                              : Container(
                                  width: 32,
                                  height: 32,
                                  decoration: const BoxDecoration(
                                      color: AppColors.primary,
                                      shape: BoxShape.circle),
                                  child: const Icon(Icons.favorite,
                                      color: Colors.white, size: 16),
                                ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 送信済みいいねの取り消し（確認ダイアログ付き）
Future<void> _confirmAndCancelLike(
    BuildContext context, WidgetRef ref, LikeEntry entry) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('いいねを取り消しますか？'),
      content: const Text('取り消すと、この相手への「いいね」はなかったことになります。\n本当によろしいですか？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('取り消す'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  try {
    await ref.read(_likesRepoProvider).cancelLike(entry.likeId);
    ref.invalidate(sentLikesProvider);
    // YAHEタブのすれ違いカードの iLiked はここで更新される encountersProvider
    // から来ている。ここを invalidate していなかったため、いいねを取り消しても
    // ハートが塗り潰されたまま（再いいね不可）で、アプリ再起動まで直らなかった。
    ref.invalidate(encountersProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('いいねを取り消しました')),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('エラーが発生しました')),
    );
  }
}

// いいね取り消しボタン（送信済み・未マッチの場合のみ表示）
class _CancelLikeButton extends StatelessWidget {
  final VoidCallback onCancel;
  const _CancelLikeButton({required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onCancel,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.close, size: 14, color: AppColors.textMuted),
            SizedBox(width: 4),
            Text('取り消す',
                style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _VehicleRow extends StatelessWidget {
  final Vehicle vehicle;
  const _VehicleRow({required this.vehicle});

  @override
  Widget build(BuildContext context) {
    final typeIcon = vehicle.vehicleType == VehicleType.bike ? LucideIcons.bike : LucideIcons.car;
    final tags = vehicle.tags.take(3).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: vehicle.photos.isNotEmpty
                    ? SignedStorageImage(
                        storedReference: vehicle.photos.first,
                        width: 52,
                        height: 38,
                        fit: BoxFit.cover,
                        placeholder: _placeholder(),
                      )
                    : _placeholder(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(typeIcon, size: 12, color: AppColors.textPrimary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            vehicle.displayName,
                            style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 4,
                        children: tags.map((t) => _Tag(t)).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (vehicle.customContent != null &&
              vehicle.customContent!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              vehicle.customContent!,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12, height: 1.4),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _placeholder() => Container(
      width: 52,
      height: 38,
      color: AppColors.surface,
      child: const Icon(Icons.directions_car,
          color: AppColors.textMuted, size: 18));
}

class _Tag extends StatelessWidget {
  final String label;
  const _Tag(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.primary.withOpacity(0.25)),
        ),
        child: Text(label,
            style: const TextStyle(
                color: AppColors.primary,
                fontSize: 10,
                fontWeight: FontWeight.w600)),
      );
}
