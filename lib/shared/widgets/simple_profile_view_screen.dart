import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/supabase/supabase_config.dart';
import '../../features/auth/presentation/auth_provider.dart';
import '../../features/home/data/encounter_repository.dart';
import '../../features/home/presentation/home_provider.dart'
    show todayLikeCountProvider;
import '../../features/likes/presentation/likes_screen.dart';
import '../../features/match/data/match_repository.dart';
import '../../features/match/presentation/match_detail_screen.dart';
import '../../features/match/presentation/match_screen.dart';
import '../../features/profile/data/user_repository.dart';
import '../../features/store/data/store_repository.dart';
import '../../features/store/models/item_model.dart';
import '../../features/store/presentation/store_screen.dart'
    show myItemsProvider, StoreScreen;
import '../../features/vehicle/data/vehicle_repository.dart';
import '../../features/vehicle/presentation/vehicle_register_provider.dart';
import '../providers/global_realtime_providers.dart';
import 'like_limit_upsell_dialog.dart';
import 'limited_profile_sheet.dart';
import 'match_celebration_dialog.dart';
import 'share_encounter_card.dart';

/// グループ・掲示板で出会った相手のプロフィールを表示する。
/// マッチ済みならマッチ画面と同じ詳細プロフィールを、未マッチなら
/// 個人情報保護のためマッチ前と同じ限定プロフィール（いいねボタン付き）を表示する。
Future<void> showUserProfile(
    BuildContext context, WidgetRef ref, String userId) async {
  final myId = ref.read(authNotifierProvider).value?.userId;
  if (myId == null || myId == userId) return;

  // Gear Rの「インサイトアクティビティ」用に閲覧数を記録する（失敗は無視）
  UserRepository().recordProfileView(userId);

  final match = await MatchRepository().fetchMatchByOtherUserId(myId, userId);
  if (match != null) {
    if (!context.mounted) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => MatchDetailScreen(match: match)));
    return;
  }

  final otherUser = await UserRepository().fetchUser(userId);
  final vehicles = await VehicleRepository().fetchAllVehicles(userId);
  final likeRow = await SupabaseConfig.client
      .from('likes')
      .select('like_id')
      .eq('from_user_id', myId)
      .eq('to_user_id', userId)
      .maybeSingle();
  final isBlocked = (ref.read(blockedUserIdsProvider).value ?? const <String>{})
      .contains(userId);
  final isBlockedByOther = await UserRepository().amIBlockedBy(userId);
  if (!context.mounted) return;

  await LimitedProfileSheet.show(
    context,
    vehicle: vehicles.isNotEmpty ? vehicles.first : null,
    otherVehicles: vehicles,
    otherUser: otherUser,
    iLiked: likeRow != null,
    isMatched: false,
    otherUserId: userId,
    currentUserId: myId,
    isBlocked: isBlocked,
    isBlockedByOther: isBlockedByOther,
    onBlocked: () => invalidateAfterBlockChange(ref),
    onLike: () async {
      try {
        final result = await EncounterRepository()
            .sendLikeNoEncounter(fromUserId: myId, toUserId: userId);
        // いいね・マッチ関連の一覧タブが古いまま（未反映）だったため、
        // 成功時は関係するプロバイダを更新しておく。
        ref.invalidate(sentLikesProvider);
        ref.invalidate(todayLikeCountProvider);
        if (!context.mounted) return;
        if (result['error'] == 'daily_limit_exceeded') {
          LikeLimitUpsellDialog.show(context);
        } else if (result['is_matched'] == true) {
          ref.invalidate(matchesProvider);
          ref.invalidate(receivedLikesProvider);
          MatchCelebrationDialog.show(
            context,
            onShare: () async {
              Navigator.of(context).maybePop();
              final me = ref.read(authNotifierProvider).value;
              if (me == null) return;
              final myVehicle = await ref.read(myVehicleProvider(myId).future);
              if (!context.mounted) return;
              await shareEncounter(
                context: context,
                occasionEmoji: '🎉',
                occasionTitle: 'マッチしました！',
                myUser: me,
                myVehicle: myVehicle,
                otherUser: otherUser,
                otherVehicle: vehicles.isNotEmpty ? vehicles.first : null,
              );
            },
            onViewMatch: () async {
              Navigator.of(context).maybePop();
              final newMatch =
                  await MatchRepository().fetchMatchByOtherUserId(myId, userId);
              if (newMatch == null || !context.mounted) return;
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => MatchDetailScreen(match: newMatch)));
            },
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('いいねに失敗しました: $e')),
          );
        }
      }
    },
    onBoostLike: () async {
      final items = ref.read(myItemsProvider).value ?? const [];
      final hasBoostItem = items.any((i) =>
          (i.type == ItemType.shibu || i.type == ItemType.gekiShibu) &&
          i.quantity > 0);
      if (!hasBoostItem) {
        if (context.mounted) _showNoBoostItemDialog(context);
        return;
      }
      try {
        final result = await StoreRepository()
            .sendBoostedLikeNoEncounter(myId, userId);
        ref.invalidate(sentLikesProvider);
        ref.invalidate(todayLikeCountProvider);
        ref.invalidate(myItemsProvider);
        if (!context.mounted) return;
        final boostLabel =
            result['boost_type'] == 'geki_shibu' ? '激渋！' : '渋！';
        if (result['error'] == 'daily_limit_exceeded') {
          LikeLimitUpsellDialog.show(context);
        } else if (result['error'] == 'no_boost_item') {
          _showNoBoostItemDialog(context);
        } else if (result['is_matched'] == true) {
          ref.invalidate(matchesProvider);
          ref.invalidate(receivedLikesProvider);
          MatchCelebrationDialog.show(
            context,
            onShare: () async {
              Navigator.of(context).maybePop();
              final me = ref.read(authNotifierProvider).value;
              if (me == null) return;
              final myVehicle = await ref.read(myVehicleProvider(myId).future);
              if (!context.mounted) return;
              await shareEncounter(
                context: context,
                occasionEmoji: '🎉',
                occasionTitle: 'マッチしました！',
                myUser: me,
                myVehicle: myVehicle,
                otherUser: otherUser,
                otherVehicle: vehicles.isNotEmpty ? vehicles.first : null,
              );
            },
            onViewMatch: () async {
              Navigator.of(context).maybePop();
              final newMatch =
                  await MatchRepository().fetchMatchByOtherUserId(myId, userId);
              if (newMatch == null || !context.mounted) return;
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => MatchDetailScreen(match: newMatch)));
            },
          );
        } else if (result['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$boostLabelを送りました')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('渋の送信に失敗しました: $e')),
          );
        }
      }
    },
  );
}

void _showNoBoostItemDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
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
