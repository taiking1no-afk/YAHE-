import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/user_model.dart';

class MatchModel {
  final String matchId;
  final String userAId;
  final String userBId;
  final DateTime matchedAt;

  // 相手側の情報（マッチング後に開示）
  final UserModel? otherUser;
  final Vehicle? otherVehicle;
  final List<Vehicle> otherVehicles;

  const MatchModel({
    required this.matchId,
    required this.userAId,
    required this.userBId,
    required this.matchedAt,
    this.otherUser,
    this.otherVehicle,
    this.otherVehicles = const [],
  });

  factory MatchModel.fromJson(Map<String, dynamic> json) => MatchModel(
        matchId: json['match_id'] as String,
        userAId: json['user_a_id'] as String,
        userBId: json['user_b_id'] as String,
        matchedAt: DateTime.parse(json['matched_at'] as String).toLocal(),
      );
}
