import '../../vehicle/models/vehicle.dart';

enum BoardParticipationStatus { interested, joined, pending, invited }

extension BoardParticipationStatusX on BoardParticipationStatus {
  static BoardParticipationStatus fromString(String v) => switch (v) {
        'interested' => BoardParticipationStatus.interested,
        'joined' => BoardParticipationStatus.joined,
        'pending' => BoardParticipationStatus.pending,
        'invited' => BoardParticipationStatus.invited,
        _ => BoardParticipationStatus.interested,
      };
}

class BoardParticipationModel {
  final String participationId;
  final String postId;
  final String userId;
  final String? vehicleId;
  final BoardParticipationStatus status;
  final DateTime createdAt;
  final String? nickname;
  final String? avatarUrl;
  final Vehicle? vehicle;

  const BoardParticipationModel({
    required this.participationId,
    required this.postId,
    required this.userId,
    this.vehicleId,
    required this.status,
    required this.createdAt,
    this.nickname,
    this.avatarUrl,
    this.vehicle,
  });

  factory BoardParticipationModel.fromJson(Map<String, dynamic> json) =>
      BoardParticipationModel(
        participationId: json['participation_id'] as String,
        postId: json['post_id'] as String,
        userId: json['user_id'] as String,
        vehicleId: json['vehicle_id'] as String?,
        status: BoardParticipationStatusX.fromString(json['status'] as String),
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  BoardParticipationModel withUser(
          {String? nickname, String? avatarUrl, Vehicle? vehicle}) =>
      BoardParticipationModel(
        participationId: participationId,
        postId: postId,
        userId: userId,
        vehicleId: vehicleId,
        status: status,
        createdAt: createdAt,
        nickname: nickname,
        avatarUrl: avatarUrl,
        vehicle: vehicle ?? this.vehicle,
      );
}
