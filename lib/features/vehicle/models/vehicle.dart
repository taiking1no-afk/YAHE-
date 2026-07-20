enum VehicleType { car, bike }

extension VehicleTypeX on VehicleType {
  String get label => this == VehicleType.car ? '車' : 'バイク';
  String get value => this == VehicleType.car ? 'car' : 'bike';
  static VehicleType fromString(String? v) =>
      v == 'bike' ? VehicleType.bike : VehicleType.car;
}

class Vehicle {
  final String vehicleId;
  final String userId;
  final VehicleType vehicleType;
  final String maker;
  final String model;
  final int? year;
  final List<String> tags;
  final String? customContent;
  final List<String> photos;
  final DateTime? deliveryDate;
  final bool isActive;
  final DateTime createdAt;

  const Vehicle({
    required this.vehicleId,
    required this.userId,
    this.vehicleType = VehicleType.car,
    required this.maker,
    required this.model,
    this.year,
    required this.tags,
    this.customContent,
    required this.photos,
    this.deliveryDate,
    required this.isActive,
    required this.createdAt,
  });

  factory Vehicle.fromJson(Map<String, dynamic> json) => Vehicle(
        vehicleId: json['vehicle_id'] as String,
        userId: json['user_id'] as String,
        vehicleType: VehicleTypeX.fromString(json['vehicle_type'] as String?),
        maker: json['maker'] as String,
        model: json['model'] as String,
        year: json['year'] as int?,
        tags: List<String>.from(json['tags'] as List? ?? []),
        customContent: json['custom_content'] as String?,
        photos: List<String>.from(json['photos'] as List? ?? []),
        deliveryDate: json['delivery_date'] != null
            ? DateTime.tryParse(json['delivery_date'] as String)
            : null,
        isActive: json['is_active'] as bool? ?? true,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  String get displayName => '$maker $model${year != null ? ' ($year)' : ''}';
}
