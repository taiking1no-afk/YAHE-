import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/user_model.dart';

class LikeEntry {
  final String likeId;
  final String encounterId;
  final String otherUserId;
  final String? otherNickname;
  final String? otherAvatarUrl;
  final Vehicle? otherVehicle;
  final List<Vehicle> otherVehicles;
  final UserModel? otherUser;
  final DateTime createdAt;
  final bool isMatched;

  const LikeEntry({
    required this.likeId,
    required this.encounterId,
    required this.otherUserId,
    this.otherNickname,
    this.otherAvatarUrl,
    this.otherVehicle,
    this.otherVehicles = const [],
    this.otherUser,
    required this.createdAt,
    required this.isMatched,
  });
}
