import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

/// 公開アカウント（鍵なし）であることを示すバッジ。
/// `encounter_card.dart` の `_VerifiedBadge` と同じ見た目パターンを踏襲。
class PublicBadge extends StatelessWidget {
  const PublicBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.success.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.success.withOpacity(0.4)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.public, color: AppColors.success, size: 12),
          SizedBox(width: 3),
          Text(
            '公開',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
