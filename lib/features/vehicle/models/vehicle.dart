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
  final String? ownerPassionComment;
  final double photoFocalX; // 一覧/サムネイル表示時のトリミング焦点(0.0〜1.0、デフォルト0.5=中央)
  final double photoFocalY;

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
    this.ownerPassionComment,
    this.photoFocalX = 0.5,
    this.photoFocalY = 0.5,
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
        ownerPassionComment: json['owner_passion_comment'] as String?,
        photoFocalX: (json['photo_focal_x'] as num?)?.toDouble() ?? 0.5,
        photoFocalY: (json['photo_focal_y'] as num?)?.toDouble() ?? 0.5,
      );

  String get displayName => '$maker $model${year != null ? ' ($year)' : ''}';
}
