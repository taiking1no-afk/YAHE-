enum CustomizationCategory { suspension, wheel, exhaust, aero, tire, other }

extension CustomizationCategoryX on CustomizationCategory {
  String get value => switch (this) {
        CustomizationCategory.suspension => 'suspension',
        CustomizationCategory.wheel => 'wheel',
        CustomizationCategory.exhaust => 'exhaust',
        CustomizationCategory.aero => 'aero',
        CustomizationCategory.other => 'other',
        CustomizationCategory.tire => 'tire',
      };

  String get label => switch (this) {
        CustomizationCategory.suspension => '車高調',
        CustomizationCategory.wheel => 'ホイール',
        CustomizationCategory.exhaust => 'マフラー',
        CustomizationCategory.aero => 'エアロ',
        CustomizationCategory.other => 'その他',
        CustomizationCategory.tire => 'タイヤ',
      };

  static CustomizationCategory fromString(String v) => switch (v) {
        'suspension' => CustomizationCategory.suspension,
        'wheel' => CustomizationCategory.wheel,
        'exhaust' => CustomizationCategory.exhaust,
        'aero' => CustomizationCategory.aero,
        'other' => CustomizationCategory.other,
        'tire' => CustomizationCategory.tire,
        _ => throw ArgumentError('unknown category: $v'),
      };
}

class VehicleCustomizationPart {
  final String? partId;
  final String vehicleId;
  final CustomizationCategory category;
  final String? brand;
  final String? specDetail;
  final String? ownerComment;
  final int displayOrder;

  const VehicleCustomizationPart({
    this.partId,
    required this.vehicleId,
    required this.category,
    this.brand,
    this.specDetail,
    this.ownerComment,
    this.displayOrder = 0,
  });

  bool get isEmpty =>
      (brand == null || brand!.isEmpty) &&
      (specDetail == null || specDetail!.isEmpty) &&
      (ownerComment == null || ownerComment!.isEmpty);

  factory VehicleCustomizationPart.fromJson(Map<String, dynamic> json) =>
      VehicleCustomizationPart(
        partId: json['part_id'] as String?,
        vehicleId: json['vehicle_id'] as String,
        category: CustomizationCategoryX.fromString(json['category'] as String),
        brand: json['brand'] as String?,
        specDetail: json['spec_detail'] as String?,
        ownerComment: json['owner_comment'] as String?,
        displayOrder: json['display_order'] as int? ?? 0,
      );

  Map<String, dynamic> toUpsertJson() => {
        'vehicle_id': vehicleId,
        'category': category.value,
        'brand': brand,
        'spec_detail': specDetail,
        'owner_comment': ownerComment,
        'display_order': displayOrder,
      };

  VehicleCustomizationPart copyWith({
    String? brand,
    String? specDetail,
    String? ownerComment,
  }) =>
      VehicleCustomizationPart(
        partId: partId,
        vehicleId: vehicleId,
        category: category,
        brand: brand ?? this.brand,
        specDetail: specDetail ?? this.specDetail,
        ownerComment: ownerComment ?? this.ownerComment,
        displayOrder: displayOrder,
      );
}
