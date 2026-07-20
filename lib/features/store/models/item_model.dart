enum ItemType { nitro, shibu, superNitro, gekiShibu, gearPlus24h }

extension ItemTypeX on ItemType {
  String get value => switch (this) {
        ItemType.nitro => 'nitro',
        ItemType.shibu => 'shibu',
        ItemType.superNitro => 'super_nitro',
        ItemType.gekiShibu => 'geki_shibu',
        ItemType.gearPlus24h => 'gear_plus_24h',
      };

  String get label => switch (this) {
        ItemType.nitro => 'ニトロ',
        ItemType.shibu => '渋！',
        ItemType.superNitro => 'スーパーニトロ',
        ItemType.gekiShibu => '激渋！',
        ItemType.gearPlus24h => '24時間ギア＋',
      };

  String get emoji => switch (this) {
        ItemType.nitro => '⚡',
        ItemType.shibu => '🔥',
        ItemType.superNitro => '💥',
        ItemType.gekiShibu => '🌟',
        ItemType.gearPlus24h => '🚀',
      };

  String get description => switch (this) {
        ItemType.nitro =>
          '1時間、すれ違った人のYAHEリスト上位に表示されます',
        ItemType.shibu =>
          'いいねされた人のリスト上位に表示されます（1個消費）',
        ItemType.superNitro =>
          '1時間、YAHEリスト最上位に表示＋目立つバッジ付き',
        ItemType.gekiShibu =>
          'いいねリスト最上位に表示＋目立つバッジ付き（1個消費）',
        ItemType.gearPlus24h =>
          'いいね無制限・すれ違い履歴7日間・愛車ガード無制限が24時間使える',
      };

  bool get isTimedItem =>
      this == ItemType.nitro || this == ItemType.superNitro || this == ItemType.gearPlus24h;

  Duration get timedDuration => switch (this) {
        ItemType.gearPlus24h => const Duration(hours: 24),
        _ => const Duration(hours: 1),
      };

  String get productId => switch (this) {
        ItemType.nitro => 'yahe_nitro_1h',
        ItemType.shibu => 'yahe_shibu_10',
        ItemType.superNitro => 'yahe_super_nitro_1h',
        ItemType.gekiShibu => 'yahe_geki_shibu_10',
        ItemType.gearPlus24h => 'yahe_gear_plus_24h',
      };

  int get priceJpy => switch (this) {
        ItemType.nitro => 200,
        ItemType.shibu => 200,
        ItemType.superNitro => 2000,
        ItemType.gekiShibu => 2000,
        ItemType.gearPlus24h => 300,
      };

  String get priceLabel => switch (this) {
        ItemType.nitro => '¥200 / 1時間',
        ItemType.shibu => '¥200 / 10個',
        ItemType.superNitro => '¥2,000 / 1時間',
        ItemType.gekiShibu => '¥2,000 / 10個',
        ItemType.gearPlus24h => '¥300 / 24時間',
      };

  static ItemType fromString(String v) => switch (v) {
        'nitro' => ItemType.nitro,
        'shibu' => ItemType.shibu,
        'super_nitro' => ItemType.superNitro,
        'geki_shibu' => ItemType.gekiShibu,
        'gear_plus_24h' => ItemType.gearPlus24h,
        _ => ItemType.nitro,
      };
}

class UserItemState {
  final ItemType type;
  final int quantity;
  final DateTime? activeUntil;

  const UserItemState({
    required this.type,
    required this.quantity,
    this.activeUntil,
  });

  bool get isActive {
    if (!type.isTimedItem) return false;
    if (activeUntil == null) return false;
    return DateTime.now().isBefore(activeUntil!);
  }

  String get remainingLabel {
    if (!isActive) return '';
    final remaining = activeUntil!.difference(DateTime.now());
    final mins = remaining.inMinutes;
    if (mins >= 60) return '${remaining.inHours}時間${mins % 60}分';
    return '$mins分';
  }

  factory UserItemState.fromJson(Map<String, dynamic> json) => UserItemState(
        type: ItemTypeX.fromString(json['item_type'] as String),
        quantity: json['quantity'] as int? ?? 0,
        activeUntil: json['active_until'] != null
            ? DateTime.tryParse(json['active_until'] as String)
            : null,
      );
}
