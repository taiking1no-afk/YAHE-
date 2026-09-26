# YAHE オーナー運用ゲート（コード外作業）

コード修正・SQL・Edge Function はリポジトリ側で完了済みです。  
以下は **App Store / Play / ドメイン / 実機** でオーナーが完了する必要があります。

最終更新: 2026-07-21

---

## A. DB / Edge（必須・すぐ）

- [ ] Supabase SQL Editor で `surf/supabase/migration_v1_28_ops_hardening.sql` を実行
- [ ] v1.24〜v1.26 が本番に入っていることを確認（未なら順に適用）
- [ ] `supabase secrets set REVENUECAT_WEBHOOK_SECRET=...`（空禁止）
- [ ] `supabase secrets set REVENUECAT_SECRET_API_KEY=...`
- [ ] Edge Functions デプロイ: `revenuecat-webhook --no-verify-jwt` / `sync-subscription` / `delete-account`
  - ※ Webhook だけ `--no-verify-jwt` 必須（そうでないと `Invalid JWT` で課金同期が届かない）
- [ ] RevenueCat Webhook Authorization = `Bearer <同じ SECRET>`
- [ ] 照合スクリプト: `bash scripts/verify_revenuecat_setup.sh`
確認 SQL（例）:

```sql
-- gear_plus_24h 無制限延長が塞がれていること
SELECT proname FROM pg_proc WHERE proname IN ('activate_timed_item','fulfill_consumable_purchase','send_like');

-- debug_seed が authenticated から呼べないこと
SELECT has_function_privilege('authenticated', 'public.debug_seed_encounters(uuid,integer)', 'EXECUTE');
-- → false が正しい

-- 課金 RPC
SELECT has_function_privilege('authenticated', 'public.sync_subscription_plan(uuid,text,timestamptz,boolean)', 'EXECUTE');
-- → false が正しい
```

---

## B. IAP 8商品（ASC / Play）

手順の詳細: `kyouzai/companies/yaeh/app-store/提出手順書.md`  
商品IDの正: `kyouzai/companies/yaeh/app-store/iap-catalog.md`

### サブスク 3

| product_id | 価格 | 備考 |
|------------|------|------|
| `yahe_pit_in_monthly` | ¥300 | entitlement `pit_in` |
| `yahe_gear_plus_monthly` | ¥500 | entitlement `gear_plus` / **初月無料 Intro** |
| `yahe_gear_r_monthly` | ¥3,000 | entitlement `gear_r` |

### 消耗型 5

| product_id | 価格 |
|------------|------|
| `yahe_nitro_1h` | ¥200 |
| `yahe_shibu_10` | ¥200 |
| `yahe_super_nitro_1h` | ¥2,000 |
| `yahe_geki_shibu_10` | ¥2,000 |
| `yahe_gear_plus_24h` | ¥300 |

- [ ] ASC に上記 8 を作成
- [ ] Play Console に上記 8 を作成（ID 完全一致）
- [ ] RevenueCat Offerings / Entitlements 紐付け
- [ ] Gear+ 初月無料 Intro を **ストア側**でも設定

---

## C. メール・特商法

- [ ] `support@yahe.jp` の MX / 転送を設定し、実受信できることを確認
- [ ] 特商法ページ（アプリ内 + https://yahe-legal.netlify.app/tokushoho ）の内容を確認
- [ ] `lp-public` を Netlify に再デプロイ（メール・開示段階の文言更新済み）

---

## D. TestFlight / 内部テスト 主要動線 QA

- [ ] ログイン（Apple / Google）
- [ ] 年齢確認・オンボーディング・権限
- [ ] すれ違い検知（実機2台）→ ホームに時刻表示
- [ ] いいね → 「いいねされた」に表示
- [ ] **別日（または期限切れ encounter）のいいね返しでマッチ**
- [ ] マッチ後 SNS 開示
- [ ] 愛車ガード ON で検知停止
- [ ] アカウント削除（失敗時にログアウトしないこと）
- [ ] Gear+ / 消耗型サンドボックス購入 → plan / アイテム反映
- [ ] 有料時に広告非表示
- [ ] Push（Release/TestFlight ビルドで本番 APNs）

---

## E. ローカルチェック

```bash
cd surf && bash scripts/pre_release_security_check.sh
```

---

## F. Gear+ 特典期間（「YAHEテスト版」名義での一般公開中は全ダウンロード者に自動付与）

**運用方針**：TestFlight外部テストではなく、実際のApp Store/Play一般公開そのものを「特典期間」として使う。表示名を「YAHEテスト版」のままにした状態で公開し、ダウンロードして登録した人（イベント参加者含む・区別しない）全員に自動でGear+を1ヶ月相当付与する。特典期間が終わったら、Gと合わせて通常の「YAHE」名義の製品版に切り替える。

- [x] Supabase SQL Editor で `surf/supabase/migration_v1_33_tester_auto_grant.sql` を実行済み
  - 新規登録した全ユーザーに Gear+ を自動付与（デフォルト90日・`source='test'`）
  - 本番環境には v1.15 の自動失効cron（`expire_premium_overrides`）が入っていないことを確認済み。ただしアプリ側（`UserModel._overrideActive`）が期限を都度その場で判定しているため、DB上の列が失効後も残っていても動作上は問題ない
- [x] `tester_auto_grant.enabled = true` のまま維持 → **「YAHEテスト版」ビルドを手動リリースした瞬間が特典期間の開始**（追加の操作は不要、既にON）

### 特典期間を終了させる時（Gと同時に実施する）

- [ ] Supabase SQL Editorで以下を順に実行

  1. その時点でまだ有効な人のoverrideを一斉に失効させる（登録時期による残り日数のばらつきをなくし、全員を同じ終了時点に揃える）
     ```sql
     UPDATE public.users
     SET premium_override_expires_at = NOW()
     WHERE premium_override_source = 'test'
       AND (premium_override_expires_at IS NULL OR premium_override_expires_at > NOW());
     ```
  2. 新規登録への自動付与を無効化する
     ```sql
     UPDATE public.app_config
     SET value = jsonb_set(value, '{enabled}', 'false'), updated_at = NOW()
     WHERE key = 'tester_auto_grant';
     ```
- [ ] 確認:
  ```sql
  SELECT value FROM public.app_config WHERE key = 'tester_auto_grant';
  -- → enabled: false であること

  SELECT COUNT(*) FROM public.users
  WHERE premium_override_source = 'test' AND premium_override_expires_at > NOW();
  -- → 0件（まだ有効なoverrideが残っていないこと）
  ```
  2を忘れると、以降も新規登録した実ユーザー全員へ無料で Gear+ が付与され続ける。

### 特典期間終了後のユーザーの扱い

override失効直後にユーザーがアプリを開くと、通常のGear+購入画面が表示される。一度も実際のストア購入（トライアル）をしていないため `gear_plus_trial_used_at` が未セットのままで、それ以降の新規ユーザーと全く同じ「1ヶ月無料で試す」ボタンが自動的に出る。そこでストアの無料トライアルに入り、以後は解約しない限り自動更新される通常のサブスクに自然移行する。

**二重取り防止の考え方**：override分の無料期間とストアトライアルの無料期間を両方フルに与えない。特典期間終了のタイミングでoverrideを一斉に切ることで、「特典期間中は無料 → 終了と同時にストアトライアル1ヶ月へ切り替わる」という1本の流れにし、特典期間中の参加者・それ以降の新規ユーザーとも公開後の無料期間は「1ヶ月」で揃える。

---

## G. 特典期間終了時に表示名を正式版へ切り替え（Fと同時に実施）

実機テスト・特典期間中は、ホーム画面のアプリ名を「YAHEテスト版」にしている。特典期間の終了（Fのoverride一斉失効・自動付与無効化）と同時に、以下を行い正式な製品版ビルドへ切り替える。

- [ ] 以下を `YAHE` に戻す
  - `ios/Runner/Info.plist` の `CFBundleDisplayName`
  - `android/app/src/main/AndroidManifest.xml` の `android:label`
- [ ] 戻したことを確認してから `./scripts/build_release_ios.sh` / `./scripts/build_release_android.sh appbundle` を実行し、製品版ビルドを作る
- [ ] iOS: ビルド番号を上げて再アップロード → App Store Connectで新ビルドに差し替えて**再審査に提出**（表示名を含むバイナリ変更のため、承認済みでも再審査になる）
- [ ] Android: Google Play Consoleの本番トラックへ新しいAABをアップロード
