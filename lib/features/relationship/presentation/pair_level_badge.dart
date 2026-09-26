import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../data/relationship_repository.dart';
import '../models/pair_relationship_model.dart';
import 'pair_album_screen.dart';

/// マッチ済みの相手との関係レベルを表示するバッジ。タップでアルバム画面へ。
class PairLevelBadge extends StatefulWidget {
  final String myUserId;
  final String otherUserId;
  final String otherNickname;
  const PairLevelBadge({
    super.key,
    required this.myUserId,
    required this.otherUserId,
    required this.otherNickname,
  });

  @override
  State<PairLevelBadge> createState() => _PairLevelBadgeState();
}

class _PairLevelBadgeState extends State<PairLevelBadge> {
  PairRelationshipModel? _relationship;

  @override
  void initState() {
    super.initState();
    RelationshipRepository().fetchRelationship(widget.otherUserId).then((r) {
      if (mounted) setState(() => _relationship = r);
    }).catchError((_) {
      // 失敗時はバッジを表示しないだけ(_relationshipはnullのまま)。
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _relationship;
    if (r == null) return const SizedBox.shrink();

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PairAlbumScreen(
            myUserId: widget.myUserId,
            otherUserId: widget.otherUserId,
            otherNickname: widget.otherNickname,
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite, color: AppColors.primary, size: 16),
            const SizedBox(width: 6),
            Text(
              '関係レベル ${r.level}',
              style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Text(
              'すれ違い${r.totalCount}回・一緒に${r.driveTogetherCount + r.eventTogetherCount}回',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 16, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
