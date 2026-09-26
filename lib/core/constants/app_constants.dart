class AppConstants {
  AppConstants._();

  // すれ違い検知
  static const double encounterRadiusMeters = 100.0;
  static const int bleScanIntervalSeconds = 10;
  static const String bleServiceUuid = 'SURF-BLE-SERVICE';

  // 無料プラン制限
  static const int freeDailyLikeLimit = 10;
  static const int freePrivacyZoneLimit = 3;
  static const Duration freeEncounterExpiry = Duration(hours: 24);
  static const Duration premiumEncounterExpiry = Duration(days: 7);

  // サブスクリプション商品ID
  static const String gearPlusProductId = 'yahe_gear_plus_monthly';
  static const String gearRProductId = 'yahe_gear_r_monthly';
  static const String pitInProductId = 'yahe_pit_in_monthly';
  static const int gearPlusPrice = 500;
  static const int pitInPrice = 300;

  // 単発購入商品ID
  static const String gearPlus24hProductId = 'yahe_gear_plus_24h';
  static const int gearPlus24hPrice = 300;

  // 深夜通知デフォルト
  static const int quietStartHour = 23;
  static const int quietEndHour = 6;

  // Supabase Storage バケット名
  static const String vehiclePhotoBucket = 'vehicle-photos';

  // 改造系統タグ一覧
  static const List<String> modificationTags = [
    'エアロ',
    '車高短',
    'マフラー',
    'ホイール',
    'エンジンチューン',
    '全塗装',
    'ラッピング',
    '車内カスタム',
    '電飾',
    'ローダウン',
    'スーパーチャージャー',
    'ターボ',
    'ワイドボディ',
    'スポイラー',
    'カーボンパーツ',
  ];

  // 無料プランの最大登録台数
  static const int freeVehicleLimit = 2;

  // 車メーカー一覧（カタカナ）
  static const List<String> carMakers = [
    'トヨタ',
    'ホンダ',
    '日産',
    'マツダ',
    'スバル',
    '三菱',
    'スズキ',
    'ダイハツ',
    'レクサス',
    'インフィニティ',
    'BMW',
    'メルセデス・ベンツ',
    'アウディ',
    'フォルクスワーゲン',
    'ポルシェ',
    'フェラーリ',
    'ランボルギーニ',
    'マクラーレン',
    'アストンマーティン',
    'フォード',
    'シボレー',
    'ダッジ',
    'その他',
  ];

  // バイクメーカー一覧（カタカナ）
  static const List<String> bikeMakers = [
    'ホンダ',
    'ヤマハ',
    'スズキ',
    'カワサキ',
    'BMW Motorrad',
    'ドゥカティ',
    'ハーレーダビッドソン',
    'トライアンフ',
    'KTM',
    'アプリリア',
    'ハスクバーナ',
    'インディアン',
    'ロイヤルエンフィールド',
    'MVアグスタ',
    'その他',
  ];

  // 後方互換（既存コードが makers を参照している箇所向け）
  static List<String> makers = carMakers;

  // SNSプラットフォーム
  static const List<Map<String, String>> snsPlatforms = [
    {'key': 'instagram', 'label': 'Instagram', 'icon': 'instagram'},
    {'key': 'twitter_x', 'label': 'X (Twitter)', 'icon': 'x'},
    {'key': 'youtube', 'label': 'YouTube', 'icon': 'youtube'},
    {'key': 'tiktok', 'label': 'TikTok', 'icon': 'tiktok'},
    {'key': 'other', 'label': 'その他URL', 'icon': 'link'},
  ];
}
