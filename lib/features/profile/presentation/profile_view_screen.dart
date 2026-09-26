import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/focal_point.dart';
import '../../../shared/widgets/public_badge.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/notification_bell_button.dart';
import '../../../shared/widgets/user_groups_section.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import 'my_car_screen.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../vehicle/presentation/vehicle_register_provider.dart';
import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/encounter_stats.dart';
import '../../../shared/models/user_model.dart';
import 'encounter_stats_provider.dart';
import 'profile_edit_screen.dart';
import '../../store/presentation/gear_r_insights_screen.dart';

class ProfileViewScreen extends ConsumerWidget {
  const ProfileViewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(authNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        title: 'プロフィール',
        showBack: false,
        actions: [
          // ベルアイコン（未読バッジ付き）
          const NotificationBellButton(),
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: AppColors.primary),
            tooltip: 'プロフィール編集',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
            ).then((_) => ref.invalidate(authNotifierProvider)),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: userAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.primary)),
        error: (_, __) => const Center(child: Text('読み込みに失敗しました')),
        data: (user) {
          if (user == null) return const Center(child: Text('ログインが必要です'));
          final vehiclesAsync = ref.watch(allVehiclesProvider(user.userId));
          final statsAsync = ref.watch(encounterStatsProvider(user.userId));

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ─── ヘッダー（プロフィール写真 + 基本情報）
                _ProfileHeader(user: user, stats: statsAsync.valueOrNull),

                // ─── SNSリンク
                if (user.snsLinks.isNotEmpty)
                  _SnsSection(snsLinks: user.snsLinks),

                // ─── 公開SNSリンク（本人確認用。マッチ後に相手へ表示される）
                _PublicSnsSection(
                  link: user.publicSnsLink,
                  onEdit: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
                  ).then((_) => ref.invalidate(authNotifierProvider)),
                ),

                // ─── インサイトアクティビティ（Gear R限定）
                if (user.isGearR)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const GearRInsightsScreen()),
                      ),
                      icon: const Icon(Icons.insights_outlined, size: 18),
                      label: const Text('インサイトアクティビティを見る'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                        side: const BorderSide(color: Color(0xFF6C63FF)),
                        foregroundColor: const Color(0xFF6C63FF),
                      ),
                    ),
                  ),

                // ─── 愛車一覧
                vehiclesAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary)),
                  ),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (vehicles) => vehicles.isEmpty
                      // 愛車未登録の場合のみ登録ボタンを表示
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const MyCarScreen()),
                              ),
                              icon: const Icon(Icons.directions_car_outlined),
                              label: const Text('愛車を登録する'),
                            ),
                          ),
                        )
                      : _VehiclesSection(vehicles: vehicles),
                ),

                // ─── 所属グループ
                UserGroupsSection(userId: user.userId),

                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─── プロフィールヘッダー ─────────────────────────────────
class _ProfileHeader extends StatelessWidget {
  final dynamic user;
  final EncounterStats? stats;
  const _ProfileHeader({required this.user, this.stats});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        children: [
          // アバター
          _Avatar(
            avatarUrl: user.avatarUrl,
            nickname: user.nickname,
            radius: 44,
            focalX: user.avatarFocalX,
            focalY: user.avatarFocalY,
          ),
          const SizedBox(height: 14),

          // ニックネーム
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  user.nickname as String? ?? '名無し',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (user.isPrivate == false) ...[
                const SizedBox(width: 6),
                const PublicBadge(),
              ],
            ],
          ),

          // 居住エリア
          if (user.area != null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.location_on_outlined,
                    size: 14, color: AppColors.textMuted),
                const SizedBox(width: 3),
                Text(
                  user.area as String,
                  style:
                      const TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
              ],
            ),
          ],

          // プランバッジ（ピットイン / Gear+ / Gear R を区別して表示）
          if (user.isPremium == true) ...[
            const SizedBox(height: 8),
            Builder(builder: (context) {
              final (label, gradient, textColor) = switch (user.effectivePlan) {
                'gear_r' => (
                    'Gear R',
                    const LinearGradient(
                        colors: [Color(0xFF6C63FF), Color(0xFF8B7FFF)]),
                    Colors.white,
                  ),
                'gear_plus' => (
                    'Gear+',
                    const LinearGradient(
                        colors: [Color(0xFFFFD700), Color(0xFFFFA500)]),
                    Colors.black,
                  ),
                _ => (
                    'ピットイン',
                    const LinearGradient(
                        colors: [Color(0xFFFF8C00), Color(0xFFFFA94D)]),
                    Colors.black,
                  ),
              };
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                      color: textColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800),
                ),
              );
            }),
          ],

          // ヤエー人数（累計・本日）
          if (stats != null) ...[
            const SizedBox(height: 14),
            _EncounterStatsRow(stats: stats!),
          ],

          // 一言コメント
          if (user.comment != null) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '"${user.comment}"',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  height: 1.6,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── ヤエー人数（累計・本日）─────────────────────────────
class _EncounterStatsRow extends StatelessWidget {
  final EncounterStats stats;
  const _EncounterStatsRow({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _StatItem(label: '累計ヤエー', value: stats.totalPeople),
          ),
          Container(width: 1, height: 28, color: AppColors.border),
          Expanded(
            child: _StatItem(label: '今日のヤエー', value: stats.todayPeople),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final int value;
  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value人',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ─── SNSリンクセクション ─────────────────────────────────
class _SnsSection extends StatelessWidget {
  final List snsLinks;
  const _SnsSection({required this.snsLinks});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SNS',
              style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: snsLinks.map((link) {
              final platform = link.platform as String;
              final url = link.url as String;
              final label = link.label as String;
              final platformLabel = AppConstants.snsPlatforms.firstWhere(
                  (p) => p['key'] == platform,
                  orElse: () => {'label': 'SNS'})['label']!;

              return GestureDetector(
                onTap: () async {
                  final uri = Uri.tryParse(url);
                  if (uri != null)
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label.isNotEmpty ? label : platformLabel,
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
          ),
        ],
      ),
    );
  }
}

// ─── 愛車一覧セクション ──────────────────────────────────
// ─── 公開SNSリンク（本人確認用。マッチ後に相手へ公開される） ────
class _PublicSnsSection extends StatelessWidget {
  final PublicSnsLink? link;
  final VoidCallback onEdit;
  const _PublicSnsSection({required this.link, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.public, size: 14, color: Color(0xFF6C63FF)),
              const SizedBox(width: 6),
              const Text('公開SNSリンク',
                  style: TextStyle(
                      color: Color(0xFF6C63FF),
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              if (link != null && !link!.isVisible) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('非表示中',
                      style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (link == null)
            GestureDetector(
              onTap: onEdit,
              child: const Text(
                '未設定です（プロフィール編集から設定できます）',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            )
          else
            GestureDetector(
              onTap: onEdit,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        link!.label?.isNotEmpty == true
                            ? link!.label!
                            : link!.url,
                        style: const TextStyle(
                            color: AppColors.textPrimary, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.edit_outlined,
                        size: 14, color: AppColors.textMuted),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VehiclesSection extends StatelessWidget {
  final List<Vehicle> vehicles;
  const _VehiclesSection({required this.vehicles});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '愛車 ${vehicles.length}台',
                style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const MyCarScreen()),
                ),
                child: const Text(
                  'タップで愛車情報編集',
                  style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...vehicles.map((v) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _VehicleCard(vehicle: v),
              )),
        ],
      ),
    );
  }
}

class _VehicleCard extends StatelessWidget {
  final Vehicle vehicle;
  const _VehicleCard({required this.vehicle});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const MyCarScreen()),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (vehicle.photos.isNotEmpty)
              ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: Stack(
                  children: [
                    SignedStorageImage(
                      storedReference: vehicle.photos.first,
                      height: 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      alignment: focalAlignment(
                          vehicle.photoFocalX, vehicle.photoFocalY),
                      placeholder: Container(
                        height: 100,
                        color: AppColors.background,
                        child: const Center(
                            child: Icon(Icons.directions_car_outlined,
                                color: AppColors.textMuted, size: 40)),
                      ),
                    ),
                    if (vehicle.photos.length > 1)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.photo_library_outlined,
                                  size: 12, color: Colors.white),
                              const SizedBox(width: 4),
                              Text(
                                '${vehicle.photos.length}枚',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              )
            else
              Container(
                height: 80,
                decoration: const BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: const Center(
                  child: Icon(Icons.directions_car_outlined,
                      color: AppColors.textMuted, size: 36),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    vehicle.displayName,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                  if (vehicle.customContent != null &&
                      vehicle.customContent!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      vehicle.customContent!,
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                          height: 1.5),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
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

// ─── 共通アバターウィジェット（イニシャル or 実画像）────────────
class _Avatar extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  final double radius;
  final double focalX;
  final double focalY;

  const _Avatar({
    required this.avatarUrl,
    required this.nickname,
    required this.radius,
    this.focalX = 0.5,
    this.focalY = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      return ClipOval(
        child: SignedStorageImage(
          storedReference: avatarUrl!,
          defaultBucket: 'profile-photos',
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          alignment: focalAlignment(focalX, focalY),
          placeholder: _initials(),
        ),
      );
    }
    return _initials();
  }

  Widget _initials() {
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primary.withOpacity(0.15),
      child: Text(
        nickname.isNotEmpty ? nickname.substring(0, 1).toUpperCase() : 'U',
        style: TextStyle(
          color: AppColors.primary,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
