import '../../vehicle/models/vehicle.dart';
import '../../../shared/models/user_model.dart';

class Encounter {
  final String encounterId;
  final String userAId;
  final String userBId;
  final DateTime time;
  final DateTime expiresAt;

  final UserModel? otherUser;
  final Vehicle? otherVehicle;
  final List<Vehicle> otherVehicles;
  final String? otherUserId;
  final bool iLiked;
  final bool isMatched;
  final int occurrenceNumber;
  final bool isSameModel;

  const Encounter({
    required this.encounterId,
    required this.userAId,
    required this.userBId,
    required this.time,
    required this.expiresAt,
    this.otherUser,
    this.otherVehicle,
    this.otherVehicles = const [],
    this.otherUserId,
    required this.iLiked,
    required this.isMatched,
    this.occurrenceNumber = 1,
    this.isSameModel = false,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Encounter copyWith({bool? isSameModel}) => Encounter(
        encounterId: encounterId,
        userAId: userAId,
        userBId: userBId,
        time: time,
        expiresAt: expiresAt,
        otherUser: otherUser,
        otherVehicle: otherVehicle,
        otherVehicles: otherVehicles,
        otherUserId: otherUserId,
        iLiked: iLiked,
        isMatched: isMatched,
        occurrenceNumber: occurrenceNumber,
        isSameModel: isSameModel ?? this.isSameModel,
      );
}
