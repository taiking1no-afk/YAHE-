import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/providers/tab_provider.dart';
import '../../../shared/widgets/limited_profile_sheet.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../ads/banner_ad_widget.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../match/presentation/match_screen.dart';
import '../../likes/presentation/likes_screen.dart';
import '../../../shared/widgets/permission_warning_banner.dart';
import 'home_provider.dart';
import 'home_layout_provider.dart';
import 'encounter_card.dart';
import 'passing_target_header.dart';
import 'same_model_effect_overlay.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

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

    ref.listen(encountersProvider, (previous, next) {
      next.whenData(_handleEncountersUpdate);
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        showBack: false,
        actions: [
          IconButton(
            tooltip: layout == HomeLayout.list ? 'グリッド表示に切り替え' : 'リスト表示に切り替え',
            icon: Icon(layout == HomeLayout.list ? Icons.grid_view_rounded : Icons.view_agenda_outlined),
            onPressed: () => ref.read(homeLayoutProvider.notifier).toggle(),
          ),
          GestureDetector(
            onLongPress: () => _showDebugDialog(context, ref, user?.userId),
            child: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(encountersProvider),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
        children: [
          const PermissionWarningBanner(),
          const PassingTargetHeader(),
          Expanded(
            child: encountersAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
        error: (e, _) => _EmptyState(onRetry: () => ref.invalidate(encountersProvider)),
        data: (encounters) {
          if (encounters.isEmpty) {
            return _EmptyState(onRetry: () => ref.invalidate(encountersProvider));
          }

          VoidCallback? buildLikeAction(dynamic encounter) {
            if (user == null) return null;
            return () async {
              final result = await ref.read(likeNotifierProvider.notifier).sendLike(
                    fromUserId: user.userId,
                    toUserId: encounter.otherUserId ?? '',
                    encounterId: encounter.encounterId,
                  );
              // いいね直後に「いいねした」一覧へ即時反映
              ref.invalidate(sentLikesProvider);
              if (!context.mounted) return;
              if (result['error'] == 'daily_limit_exceeded') {
                _showLimitDialog(context);
              } else if (result['is_matched'] == true) {
                ref.invalidate(matchesProvider);
                ref.invalidate(receivedLikesProvider);
                _showMatchDialog(context, ref);
              }
            };
          }

          void openProfile(dynamic encounter, VoidCallback? likeAction) {
            LimitedProfileSheet.show(
              context,
              vehicle: encounter.otherVehicle,
              otherVehicles: encounter.otherVehicles,
              otherUser: encounter.otherUser,
              iLiked: encounter.iLiked ?? false,
              isMatched: encounter.isMatched ?? false,
              onLike: likeAction,
              otherUserId: encounter.otherUserId,
              currentUserId: user?.userId,
              onBlocked: () {
                ref.invalidate(encountersProvider);
                ref.invalidate(matchesProvider);
              },
            );
          }

          if (layout == HomeLayout.grid) {
            return RefreshIndicator(
              color: AppColors.primary,
              backgroundColor: AppColors.surface,
              onRefresh: () async => ref.invalidate(encountersProvider),
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 3 / 4,
                ),
                itemCount: encounters.length,
                itemBuilder: (context, index) {
                  final encounter = encounters[index];
                  final likeAction = buildLikeAction(encounter);
                  return GestureDetector(
                    onTap: () => openProfile(encounter, likeAction),
                    child: EncounterGridCard(
                      encounter: encounter,
                      onLike: likeAction,
                    ),
                  );
                },
              ),
            );
          }

          // ランダム間隔（2〜5件ごと）で広告を挿入
          final items = _buildItemsWithAds(encounters);

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

                // タップで限定プロフィールシートを表示
                return GestureDetector(
                  onTap: () => openProfile(encounter, likeAction),
                  child: EncounterCard(
                    encounter: encounter,
                    onLike: likeAction,
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
      ),
    );
  }

  void _showLimitDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Text('本日のいいね上限'),
        content: const Text('無料プランは1日10回までです。\nGear+にアップグレードすると無制限になります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Gear+を見る'),
          ),
        ],
      ),
    );
  }

  void _showDebugDialog(BuildContext context, WidgetRef ref, String? myUserId) {
    if (myUserId == null) return;
    final partnerController = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Text('🛠 テストすれ違い挿入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('あなたのID:\n$myUserId',
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
            const SizedBox(height: 8),
            const Text(
              '空欄のままでOK（固定テストユーザーを使用）\nまたは別アカウントのuserIdを入力',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: partnerController,
              decoration: const InputDecoration(
                labelText: '相手のuserId（省略可）',
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () async {
              final partnerId = partnerController.text.trim();
              Navigator.pop(context);
              try {
                await ref.read(debugInsertEncounterProvider(
                  (myUserId: myUserId, partnerUserId: partnerId),
                ).future);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('テストすれ違い3件を挿入しました ✅')),
                  );
                  ref.invalidate(encountersProvider);
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('エラー: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('挿入する'),
          ),
        ],
      ),
    );
  }

  void _showMatchDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Row(
          children: [
            Icon(Icons.favorite, color: AppColors.primary),
            SizedBox(width: 8),
            Text('マッチしました！'),
          ],
        ),
        content: const Text('相互いいね成立！\nマッチタブからSNSで繋がりましょう。'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(selectedTabProvider.notifier).state = 2;
            },
            child: const Text('マッチを見る'),
          ),
        ],
      ),
    );
  }
}

// ランダム間隔（2〜5件）で広告を挿入するヘルパー
List<dynamic> _buildItemsWithAds(List<dynamic> encounters) {
  final rng = Random();
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

class _EmptyState extends StatelessWidget {
  final VoidCallback? onRetry;
  const _EmptyState({this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
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
              style: TextStyle(color: AppColors.textMuted, fontSize: 13, height: 1.7),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              TextButton(
                onPressed: onRetry,
                child: const Text('更新する'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
