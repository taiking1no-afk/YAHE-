class PrivacyZone {
  final String zoneId;
  final String userId;
  final double lat;
  final double lng;
  final int radiusM;
  final String label;
  final bool isActive;
  final DateTime createdAt;

  const PrivacyZone({
    required this.zoneId,
    required this.userId,
    required this.lat,
    required this.lng,
    required this.radiusM,
    required this.label,
    required this.isActive,
    required this.createdAt,
  });

  factory PrivacyZone.fromJson(Map<String, dynamic> json) => PrivacyZone(
        zoneId: json['zone_id'] as String,
        userId: json['user_id'] as String,
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        radiusM: json['radius_m'] as int,
        label: json['label'] as String? ?? 'その他',
        isActive: json['is_active'] as bool? ?? true,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  PrivacyZone copyWith({bool? isActive}) => PrivacyZone(
        zoneId: zoneId,
        userId: userId,
        lat: lat,
        lng: lng,
        radiusM: radiusM,
        label: label,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt,
      );
}
