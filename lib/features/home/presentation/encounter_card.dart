import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../profile/data/user_repository.dart';
import '../../vehicle/models/vehicle.dart';
import '../models/encounter.dart';

class BoostBadge extends StatelessWidget {
  final String emoji;
  final String label;
  const BoostBadge({super.key, required this.emoji, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 10)),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class EncounterCard extends StatelessWidget {
  final Encounter encounter;
  final VoidCallback? onLike;

  const EncounterCard({
    super.key,
    required this.encounter,
    this.onLike,
  });

  @override
  Widget build(BuildContext context) {
    final vehicles = encounter.otherVehicles;
    final primaryVehicle = encounter.otherVehicle;
    final otherUser = encounter.otherUser;
    final timeStr = DateFormat('M月d日 HH:mm').format(encounter.time);
    final otherId = encounter.otherUserId ?? otherUser?.userId;

    return _ProfileViewRecorder(
      viewedUserId: otherId,
      child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: encounter.isMatched
              ? AppColors.primary
              : encounter.isSameModel
                  ? const Color(0xFFFFC107)
                  : AppColors.border,
          width: encounter.isMatched || encounter.isSameModel ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // メイン写真
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: _VehiclePhoto(photoUrl: primaryVehicle?.photos.firstOrNull),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ニックネーム + いいね/マッチ
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ニックネーム + 認証バッジ
                          if (otherUser != null)
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    otherUser.nickname,
                                    style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (otherUser.isVerified && otherUser.verifiedLabel != null && otherUser.verifiedLabel!.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  _VerifiedBadge(label: otherUser.verifiedLabel!),
                                ],
                                if (encounter.isSameModel) ...[
                                  const SizedBox(width: 6),
                                  const _SameModelBadge(),
                                ],
                              ],
                            ),
                          // 一言コメント
                          if (otherUser?.comment != null && otherUser!.comment!.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              '"${otherUser.comment!}"',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                                height: 1.4,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: 6),
                          // すれ違い時刻 + 回数バッジ
                          Row(
                            children: [
                              Text(
                                '$timeStr にすれ違い',
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                              if (encounter.occurrenceNumber > 1) ...[
                                const SizedBox(width: 6),
                                _RepeatBadge(count: encounter.occurrenceNumber),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          // 記録の保持期限までの残り時間
                          _ExpiryLabel(expiresAt: encounter.expiresAt),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (encounter.isMatched)
                      _MatchBadge()
                    else
                      _LikeButton(
                        iLiked: encounter.iLiked,
                        onTap: onLike,
                      ),
                  ],
                ),

                // 愛車一覧（複数台）
                if (vehicles.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 10),
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

/// グリッド表示用のコンパクトなすれ違いカード（2列表示）
class EncounterGridCard extends StatelessWidget {
  final Encounter encounter;
  final VoidCallback? onLike;

  const EncounterGridCard({
    super.key,
    required this.encounter,
    this.onLike,
  });

  Duration get _expiryRemaining => encounter.expiresAt.difference(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final primaryVehicle = encounter.otherVehicle;
    final otherUser = encounter.otherUser;
    final otherId = encounter.otherUserId ?? otherUser?.userId;

    return _ProfileViewRecorder(
      viewedUserId: otherId,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: encounter.isMatched
                  ? AppColors.primary
                  : encounter.isSameModel
                      ? const Color(0xFFFFC107)
                      : AppColors.border,
              width: encounter.isMatched || encounter.isSameModel ? 1.5 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _VehiclePhoto(photoUrl: primaryVehicle?.photos.firstOrNull),
                // 下部グラデーション + テキスト
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
                        if (otherUser != null)
                          Text(
                            otherUser.nickname,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (primaryVehicle != null)
                          Text(
                            primaryVehicle.displayName,
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (!_expiryRemaining.isNegative)
                          Text(
                            'あと${formatRemainingDuration(_expiryRemaining)}',
                            style: const TextStyle(color: Colors.white54, fontSize: 10),
                          ),
                      ],
                    ),
                  ),
                ),
                // 右上バッジ類
                Positioned(
                  top: 6,
                  right: 6,
                  child: encounter.isMatched
                      ? _MatchBadge()
                      : _LikeButton(iLiked: encounter.iLiked, onTap: onLike, compact: true),
                ),
                if (encounter.occurrenceNumber > 1)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _RepeatBadge(count: encounter.occurrenceNumber),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// すれ違いカード表示時にプロフィール閲覧を記録（Gear R 月次解析用）
class _ProfileViewRecorder extends StatefulWidget {
  final String? viewedUserId;
  final Widget child;
  const _ProfileViewRecorder({required this.viewedUserId, required this.child});

  @override
  State<_ProfileViewRecorder> createState() => _ProfileViewRecorderState();
}

class _ProfileViewRecorderState extends State<_ProfileViewRecorder> {
  @override
  void initState() {
    super.initState();
    final id = widget.viewedUserId;
    if (id != null && id.isNotEmpty) {
      UserRepository().recordProfileView(id);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// 1台分の車両行
class _VehicleRow extends StatelessWidget {
  final Vehicle vehicle;
  const _VehicleRow({required this.vehicle});

  @override
  Widget build(BuildContext context) {
    final typeLabel = vehicle.vehicleType == VehicleType.bike ? '🏍' : '🚗';
    final tags = vehicle.tags.take(3).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // サムネイル
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: vehicle.photos.isNotEmpty
                    ? SignedStorageImage(
                        storedReference: vehicle.photos.first,
                        width: 56,
                        height: 40,
                        fit: BoxFit.cover,
                        placeholder: _photoPlaceholder(),
                      )
                    : _photoPlaceholder(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(typeLabel, style: const TextStyle(fontSize: 12)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            vehicle.displayName,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        children: tags.map((tag) => _Tag(tag)).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (vehicle.customContent != null && vehicle.customContent!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              vehicle.customContent!,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _photoPlaceholder() => Container(
        width: 56,
        height: 40,
        color: AppColors.surface,
        child: const Icon(Icons.directions_car, color: AppColors.textMuted, size: 20),
      );
}

class _Tag extends StatelessWidget {
  final String label;
  const _Tag(this.label);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.primary.withOpacity(0.25)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _VehiclePhoto extends StatelessWidget {
  final String? photoUrl;
  const _VehiclePhoto({this.photoUrl});

  @override
  Widget build(BuildContext context) {
    if (photoUrl == null) {
      return Container(
        height: 160,
        color: AppColors.surface,
        child: const Center(
          child: Icon(Icons.directions_car, color: AppColors.textMuted, size: 48),
        ),
      );
    }
    return SignedStorageImage(
      storedReference: photoUrl!,
      height: 160,
      width: double.infinity,
      fit: BoxFit.cover,
      placeholder: Container(height: 160, color: AppColors.shimmerBase),
    );
  }
}

class _LikeButton extends StatelessWidget {
  final bool iLiked;
  final VoidCallback? onTap;
  final bool compact;

  const _LikeButton({required this.iLiked, this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final size = compact ? 32.0 : 52.0;
    return GestureDetector(
      onTap: iLiked ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: iLiked ? AppColors.primary : (compact ? Colors.black45 : AppColors.surface),
          shape: BoxShape.circle,
          border: compact
              ? null
              : Border.all(
                  color: iLiked ? AppColors.primary : AppColors.border,
                  width: 1.5,
                ),
        ),
        child: Icon(
          iLiked ? Icons.favorite : Icons.favorite_border,
          color: iLiked ? Colors.white : (compact ? Colors.white : AppColors.textMuted),
          size: compact ? 16 : 22,
        ),
      ),
    );
  }
}

class _RepeatBadge extends StatelessWidget {
  final int count;
  const _RepeatBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFB74D)),
      ),
      child: Text(
        '$count回目',
        style: const TextStyle(
          color: Color(0xFFE65100),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// 記録の保持期限までの残り時間（無料: 24時間 / サブスク: 7日 で自動削除される）
class _ExpiryLabel extends StatelessWidget {
  final DateTime expiresAt;
  const _ExpiryLabel({required this.expiresAt});

  @override
  Widget build(BuildContext context) {
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.timer_outlined, size: 12, color: AppColors.textMuted),
        const SizedBox(width: 3),
        Text(
          'あと${formatRemainingDuration(remaining)}で記録が消えます',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

// "2日" "5時間" "30分" のような残り時間表記に整形する
String formatRemainingDuration(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}日';
  if (d.inHours >= 1) return '${d.inHours}時間';
  if (d.inMinutes >= 1) return '${d.inMinutes}分';
  return '1分未満';
}

class _SameModelBadge extends StatelessWidget {
  const _SameModelBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFC107).withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFFFC107)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('✨', style: TextStyle(fontSize: 9)),
          SizedBox(width: 2),
          Text(
            '同車種',
            style: TextStyle(
              color: Color(0xFFB28704),
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _MatchBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary),
      ),
      child: const Text(
        'MATCH',
        style: TextStyle(
          color: AppColors.primary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _VerifiedBadge extends StatelessWidget {
  final String label;
  const _VerifiedBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF6C63FF).withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified, color: Color(0xFF6C63FF), size: 12),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6C63FF),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
