import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/user_model.dart';

class MatchModel {
  final String matchId;
  final String userAId;
  final String userBId;
  final DateTime matchedAt;
  final bool celebratedByA;
  final bool celebratedByB;
  final DateTime? dissolvedAt;

  // 相手側の情報（マッチング後に開示）
  final UserModel? otherUser;
  final Vehicle? otherVehicle;
  final List<Vehicle> otherVehicles;

  const MatchModel({
    required this.matchId,
    required this.userAId,
    required this.userBId,
    required this.matchedAt,
    this.celebratedByA = false,
    this.celebratedByB = false,
    this.dissolvedAt,
    this.otherUser,
    this.otherVehicle,
    this.otherVehicles = const [],
  });

  /// 自分側のお祝いポップアップを表示済みか。
  bool isCelebratedBy(String myUserId) =>
      myUserId == userAId ? celebratedByA : celebratedByB;

  /// マッチが解消済みか（解消後もチャット履歴は残るが新規送信はできない）。
  bool get isDissolved => dissolvedAt != null;

  factory MatchModel.fromJson(Map<String, dynamic> json) => MatchModel(
        matchId: json['match_id'] as String,
        userAId: json['user_a_id'] as String,
        userBId: json['user_b_id'] as String,
        matchedAt: DateTime.parse(json['matched_at'] as String).toLocal(),
        celebratedByA: json['celebrated_by_a'] as bool? ?? false,
        celebratedByB: json['celebrated_by_b'] as bool? ?? false,
        dissolvedAt: json['dissolved_at'] != null
            ? DateTime.tryParse(json['dissolved_at'] as String)
            : null,
      );

  MatchModel copyWith({
    UserModel? otherUser,
    Vehicle? otherVehicle,
    List<Vehicle>? otherVehicles,
  }) =>
      MatchModel(
        matchId: matchId,
        userAId: userAId,
        userBId: userBId,
        matchedAt: matchedAt,
        celebratedByA: celebratedByA,
        celebratedByB: celebratedByB,
        dissolvedAt: dissolvedAt,
        otherUser: otherUser ?? this.otherUser,
        otherVehicle: otherVehicle ?? this.otherVehicle,
        otherVehicles: otherVehicles ?? this.otherVehicles,
      );
}
