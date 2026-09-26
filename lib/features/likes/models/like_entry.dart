import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/user_model.dart';

class LikeEntry {
  final String likeId;
  final String? encounterId;
  final String otherUserId;
  final String? otherNickname;
  final String? otherAvatarUrl;
  final Vehicle? otherVehicle;
  final List<Vehicle> otherVehicles;
  final UserModel? otherUser;
  final DateTime createdAt;
  final bool isMatched;
  final DateTime? seenAt;
  // このいいねに渋！/激渋！が使われている場合のみ非null（相手にはこの
  // いいねだけが目立って表示される）。null=通常のいいね。
  final String? boostType;

  const LikeEntry({
    required this.likeId,
    this.encounterId,
    required this.otherUserId,
    this.otherNickname,
    this.otherAvatarUrl,
    this.otherVehicle,
    this.otherVehicles = const [],
    this.otherUser,
    required this.createdAt,
    required this.isMatched,
    this.seenAt,
    this.boostType,
  });
}
