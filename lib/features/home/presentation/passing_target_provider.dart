import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../profile/data/user_repository.dart';
import '../../vehicle/models/vehicle.dart';
import '../models/passing_target.dart';

final userRepositoryProvider =
    Provider<UserRepository>((ref) => UserRepository());

/// 登録済み愛車から自分のすれ違い種別（アイデンティティ）を導出
Set<VehicleType> identityTypesFromVehicles(List<Vehicle> vehicles) {
  return vehicles.map((v) => v.vehicleType).toSet();
}

String identityLabel(Set<VehicleType> types) {
  if (types.isEmpty) return '愛車未登録';
  if (types.length == 2) return '車・バイク';
  return types.first == VehicleType.bike ? 'バイカー' : '車のり';
}

String identityDetail(Set<VehicleType> types) {
  if (types.isEmpty) {
    return '愛車を登録すると、車のり／バイカーとしてすれ違い検知されます';
  }
  if (types.length == 2) {
    return '車・バイク両方登録済み → どちらの種別としても検知されます';
  }
  return types.first == VehicleType.bike
      ? 'バイクのみ登録 → バイカーとして検知されます'
      : '車のみ登録 → 車のりとして検知されます';
}

/// 相手の愛車が自分のすれ違い対象に合うか（表示フィルタ用）
bool matchesPassingTarget(PassingTarget target, List<Vehicle> otherVehicles) {
  if (otherVehicles.isEmpty) return false;
  final types = identityTypesFromVehicles(otherVehicles);
  switch (target) {
    case PassingTarget.car:
      return types.contains(VehicleType.car);
    case PassingTarget.bike:
      return types.contains(VehicleType.bike);
    case PassingTarget.both:
      return true;
  }
}

class PassingTargetNotifier extends Notifier<PassingTarget> {
  @override
  PassingTarget build() {
    final user = ref.watch(authNotifierProvider).value;
    return user?.passingTarget ?? PassingTarget.both;
  }

  Future<void> setTarget(PassingTarget target) async {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) return;

    state = target;
    await ref.read(userRepositoryProvider).setPassingTarget(user.userId, target);
    ref.invalidate(authNotifierProvider);
  }
}

final passingTargetProvider =
    NotifierProvider<PassingTargetNotifier, PassingTarget>(
  PassingTargetNotifier.new,
);
