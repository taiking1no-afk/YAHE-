import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/utils/external_link.dart';
import '../../../core/constants/app_constants.dart';
import '../../../shared/providers/list_grid_layout_provider.dart';
import '../../../shared/widgets/ad_grid_helper.dart';
import '../../../shared/widgets/invite_to_board_sheet.dart';
import '../../../shared/widgets/public_badge.dart';
import '../../../shared/widgets/sample_timeline_preview.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../ads/banner_ad_widget.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../vehicle/models/vehicle.dart';
import '../data/match_repository.dart';
import '../models/match_model.dart';
import 'match_detail_screen.dart';

const _matchLayoutKey = 'match';

final matchRepositoryProvider =
    Provider<MatchRepository>((ref) => MatchRepository());

final matchesProvider = FutureProvider<List<MatchModel>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];
  final repo = ref.read(matchRepositoryProvider);
  return repo.fetchMatches(user.userId);
});

class MatchScreen extends ConsumerWidget {
  /// 統合タブ（SocialHubScreen）内に埋め込む場合はtrue。
  final bool embedded;
  const MatchScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchesAsync = ref.watch(matchesProvider);
    final layout = ref.watch(listGridLayoutProvider(_matchLayoutKey));

    final actions = [
      IconButton(
        tooltip: layout == ListGridLayout.list ? 'グリッド表示に切り替え' : 'リスト表示に切り替え',
        icon: Icon(layout == ListGridLayout.list
            ? Icons.grid_view_rounded
            : Icons.view_agenda_outlined),
        onPressed: () =>
            ref.read(listGridLayoutProvider(_matchLayoutKey).notifier).toggle(),
      ),
    ];

    final body = RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: () async => ref.invalidate(matchesProvider),
      child: matchesAsync.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (e, _) => const Center(child: Text('読み込みに失敗しました')),
      data: (matches) {
        if (matches.isEmpty) {
          return _EmptyState();
        }

        void openDetail(MatchModel match) => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MatchDetailScreen(match: match)),
            );

        // 無料ユーザーのみ広告を挿入
        final isPremium =
            ref.watch(authNotifierProvider).value?.isPremium ?? false;

        if (layout == ListGridLayout.grid) {
          Widget gridCard(BuildContext context, MatchModel match) =>
              GestureDetector(
                onTap: () => openDetail(match),
                child: _MatchGridCard(match: match),
              );

          if (!isPremium) {
            return CustomScrollView(
              slivers: buildAdInterleavedGridSlivers<MatchModel>(
                items: matches,
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
            itemCount: matches.length,
            itemBuilder: (context, i) => gridCard(context, matches[i]),
          );
        }

        if (isPremium) {
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: matches.length,
            itemBuilder: (context, i) {
              final match = matches[i];
              return GestureDetector(
                onTap: () => openDetail(match),
                child: _MatchCard(match: match),
              );
            },
          );
        }
        final items = _buildMatchItemsWithAds(matches);
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item == 'ad') return const InlineBannerAdCard();
            final match = item as MatchModel;
            return GestureDetector(
              onTap: () => openDetail(match),
              child: _MatchCard(match: match),
            );
          },
        );
      },
      ),
    );

    if (embedded) {
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
      appBar: YaheAppBar(title: 'マッチ', showBack: false, actions: actions),
      body: body,
    );
  }
}

// 固定シードで、providerの更新等での再構築のたびに広告位置が
// 入れ替わってちらつくのを防ぐ（ad_grid_helper.dartの他画面と同じ方針）。
List<dynamic> _buildMatchItemsWithAds(List<MatchModel> matches) {
  final rng = Random(42);
  final items = <dynamic>[];
  int nextAdAt = 2 + rng.nextInt(4);
  int count = 0;
  for (final m in matches) {
    items.add(m);
    count++;
    if (count >= nextAdAt) {
      items.add('ad');
      count = 0;
      nextAdAt = 2 + rng.nextInt(4);
    }
  }
  return items;
}

class _MatchCard extends ConsumerWidget {
  final MatchModel match;
  const _MatchCard({required this.match});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = match.otherUser;
    final vehicles = match.otherVehicles;
    final primaryVehicle = match.otherVehicle;
    final dateStr = DateFormat('M月d日').format(match.matchedAt);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withOpacity(0.4)),
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
                height: 150,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            )
          else
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: Container(
                height: 80,
                color: AppColors.surface,
                child: const Center(
                    child: Icon(Icons.directions_car,
                        color: AppColors.textMuted, size: 36)),
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ニックネーム + マッチ日
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  user?.nickname ?? '名無し',
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (user?.isPrivate == false) ...[
                                const SizedBox(width: 6),
                                const PublicBadge(),
                              ],
                            ],
                          ),
                          if (user?.comment != null &&
                              user!.comment!.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              '"${user.comment!}"',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('MATCH',
                              style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800)),
                        ),
                        const SizedBox(height: 4),
                        Text(dateStr,
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 11)),
                      ],
                    ),
                  ],
                ),

                // エリア
                if (user?.area != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.location_on_outlined,
                          size: 13, color: AppColors.textMuted),
                      const SizedBox(width: 3),
                      Text(user!.area!,
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12)),
                    ],
                  ),
                ],

                // 愛車一覧
                if (vehicles.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 8),
                  ...vehicles.map((v) => _MatchVehicleRow(vehicle: v)),
                ],

                // SNSリンク
                if (user != null && user.snsLinks.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Divider(color: AppColors.border, height: 1),
                  const SizedBox(height: 10),
                  _SnsLinks(
                    snsLinks: user.snsLinks,
                    ownerUserId: user.userId,
                  ),
                ],

                if (user != null) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => showInviteToBoardSheet(context, ref,
                          targetUserIds: [user.userId],
                          chatMatchId: match.matchId),
                      icon:
                          const Icon(Icons.event_available_outlined, size: 16),
                      label: const Text('ツーリング・イベントに誘う',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── マッチカード（グリッド表示用） ────────────────────────────
class _MatchGridCard extends StatelessWidget {
  final MatchModel match;
  const _MatchGridCard({required this.match});

  @override
  Widget build(BuildContext context) {
    final user = match.otherUser;
    final primaryVehicle = match.otherVehicle;
    final dateStr = DateFormat('M月d日').format(match.matchedAt);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: AppColors.primary.withOpacity(0.4), width: 1.5),
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              user?.nickname ?? '名無し',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (user?.isPrivate == false) ...[
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
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('MATCH',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(dateStr,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MatchVehicleRow extends StatelessWidget {
  final Vehicle vehicle;
  const _MatchVehicleRow({required this.vehicle});

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
                          children: tags.map((t) => _SmallTag(t)).toList()),
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

class _SmallTag extends StatelessWidget {
  final String label;
  const _SmallTag(this.label);
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

class _SnsLinks extends StatelessWidget {
  final List snsLinks;
  final String? ownerUserId;
  const _SnsLinks({required this.snsLinks, this.ownerUserId});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: snsLinks.map((link) {
        final platform = link.platform as String;
        final url = link.url as String;
        final label = link.label as String;

        return GestureDetector(
          onTap: () => openExternalLink(
            context,
            url,
            ownerUserId: ownerUserId,
            platform: platform,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PlatformIcon(platform: platform),
                const SizedBox(width: 6),
                Text(
                  label.isNotEmpty
                      ? '${_platformLabel(platform)}：$label'
                      : _platformLabel(platform),
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 13),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.open_in_new,
                    size: 12, color: AppColors.textMuted),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String _platformLabel(String platform) {
    final found = AppConstants.snsPlatforms.firstWhere(
      (p) => p['key'] == platform,
      orElse: () => {'label': 'SNS'},
    );
    return found['label']!;
  }
}

class _PlatformIcon extends StatelessWidget {
  final String platform;
  const _PlatformIcon({required this.platform});

  @override
  Widget build(BuildContext context) {
    final icon = switch (platform) {
      'instagram' => Icons.camera_alt_outlined,
      'twitter_x' => Icons.close,
      'youtube' => Icons.play_circle_outline,
      'tiktok' => Icons.music_note_outlined,
      _ => Icons.link,
    };
    return Icon(icon, size: 16, color: AppColors.textSecondary);
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.favorite_border,
              size: 64, color: AppColors.textMuted),
          const SizedBox(height: 16),
          const Text(
            'まだマッチはありません',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '気になる車にいいねしましょう',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 32),
          const SampleTimelinePreview(
            sampleName: 'サンプルユーザー',
            sampleSubtitle: 'マッチ日: ◯月◯日',
            description: '相互にいいねするとマッチが成立し、ここに表示されます。SNSで繋がることもできます。',
          ),
        ],
      ),
    );
  }
}
