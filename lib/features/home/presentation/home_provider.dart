import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/encounter_repository.dart';
import '../models/encounter.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../vehicle/models/vehicle.dart';
import '../../vehicle/presentation/vehicle_register_provider.dart';
import 'passing_target_provider.dart';

final encounterRepositoryProvider =
    Provider<EncounterRepository>((ref) => EncounterRepository());

final encountersProvider = FutureProvider<List<Encounter>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];

  final target = ref.watch(passingTargetProvider);
  final repo = ref.read(encounterRepositoryProvider);
  final myVehicles = await ref
      .watch(allVehiclesProvider(user.userId).future)
      .catchError((_) => <Vehicle>[]);
  final encounters = await repo.fetchEncounters(user.userId);

  final myModels = myVehicles
      .map((v) => '${v.maker.trim().toLowerCase()}|${v.model.trim().toLowerCase()}')
      .toSet();

  return encounters
      .where((e) => matchesPassingTarget(target, e.otherVehicles))
      .map((e) {
        final sameModel = e.otherVehicles.any((v) => myModels.contains(
            '${v.maker.trim().toLowerCase()}|${v.model.trim().toLowerCase()}'));
        return e.copyWith(isSameModel: sameModel);
      })
      .toList();
});

class LikeNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<Map<String, dynamic>> sendLike({
    required String fromUserId,
    required String toUserId,
    required String encounterId,
  }) async {
    final repo = ref.read(encounterRepositoryProvider);
    final result = await repo.sendLike(
      fromUserId: fromUserId,
      toUserId: toUserId,
      encounterId: encounterId,
    );
    ref.invalidate(encountersProvider);
    return result;
  }
}

final likeNotifierProvider = AsyncNotifierProvider<LikeNotifier, void>(LikeNotifier.new);

/// デバッグ用：テストすれ違いを挿入してリストを更新
/// partnerUserId が空の場合は固定テストユーザーを使用
final debugInsertEncounterProvider =
    FutureProvider.family<void, ({String myUserId, String partnerUserId})>(
  (ref, args) async {
    final repo = ref.read(encounterRepositoryProvider);
    await repo.debugInsertTestEncounters(
      myUserId: args.myUserId,
      partnerUserId: args.partnerUserId.isEmpty ? null : args.partnerUserId,
    );
    ref.invalidate(encountersProvider);
  },
);
