# SURF — すれ違いマッチングアプリ

改造車・スポーツカーオーナー向けすれ違いマッチングアプリ

## セットアップ手順

### 1. Flutter インストール
```bash
# Flutter SDK をインストール
# https://docs.flutter.dev/get-started/install
flutter pub get
```

### 2. Supabase プロジェクト作成
1. [supabase.com](https://supabase.com) でプロジェクト作成
2. `supabase/schema.sql` を SQL Editor で実行
3. Storage バケット `vehicle-photos` を作成（Public）

### 3. 環境変数設定
```bash
# dart-define で注入（本番推奨）
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT_ID.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

または `lib/core/supabase/supabase_config.dart` の defaultValue を直接編集（開発時のみ）

### 4. Firebase セットアップ（FCM通知）
```bash
dart pub global activate flutterfire_cli
flutterfire configure
```

### 5. RevenueCat セットアップ（Gear+決済）
- `purchases_flutter` の API Key を設定
- App Store Connect / Google Play で商品 `surf_gear_plus_monthly` を作成

### 6. AdMob セットアップ
- `android/app/src/main/AndroidManifest.xml` に AdMob App ID を追記
- `ios/Runner/Info.plist` に AdMob App ID を追記

## プロジェクト構造

```
lib/
├── main.dart                   # エントリーポイント
├── app.dart                    # MaterialApp + GoRouter
├── core/
│   ├── constants/              # 色・定数
│   ├── router/                 # go_router
│   ├── supabase/               # Supabase設定
│   └── theme/                  # テーマ
├── features/
│   ├── auth/                   # 認証（Apple/Google）
│   ├── vehicle/                # 車両登録（Step1〜3）
│   ├── home/                   # タイムライン・いいね
│   ├── match/                  # マッチリスト
│   ├── profile/                # マイカー・統計
│   ├── settings/               # 設定・愛車ガード
│   └── ble/                    # BLE+GPS検知サービス
└── shared/
    ├── models/                 # 共通モデル
    └── widgets/                # 共通ウィジェット
supabase/
└── schema.sql                  # DBスキーマ・RLS・Function
```

## 技術スタック

| 分類 | 技術 |
|------|------|
| フロント | Flutter / Dart |
| 状態管理 | Riverpod |
| ルーター | go_router |
| BaaS | Supabase（DB + Auth + Storage） |
| 決済 | RevenueCat |
| 広告 | AdMob |
| 通知 | FCM / APNs |
| BLE | flutter_blue_plus |
| GPS | geolocator |
| 地図 | flutter_map (OpenStreetMap) |

## プライバシー設計

- **位置情報**: すれ違い検知にのみ使用。座標はサーバーに保存しない
- **ナンバープレート**: アップロード時にAI自動モザイク処理（Supabase Edge Function連携）
- **情報開示3段階**: 相互いいね後にのみニックネーム・SNSリンクが開示される
- **愛車ガード**: 自宅・職場周辺をゾーン設定でき、ゾーン内はすれ違い非記録
