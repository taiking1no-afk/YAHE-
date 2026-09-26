# RevenueCat Webhook / 課金同期 セットアップ

Apple / Google 経由の課金はクライアントを信用せず、サーバー側だけで `users.plan` / アイテムを更新します。

## 仕組み

```
App Store / Play 課金
  → RevenueCat
    → ① Webhook → supabase/functions/revenuecat-webhook
    → ② 購入直後のアプリ → supabase/functions/sync-subscription
         （RevenueCat Secret API で検証してから反映）
```

消耗型は `fulfill_consumable_purchase`（txn 冪等）で付与するため、Webhook と sync が同時でも二重付与しません。

## 1. Supabase Secrets（必須）

```bash
supabase secrets set REVENUECAT_SECRET_API_KEY=sk_xxxxx
supabase secrets set REVENUECAT_WEBHOOK_SECRET="$(openssl rand -hex 32)"
```

- `REVENUECAT_SECRET_API_KEY`: RevenueCat → Project Settings → API Keys → **Secret key**
- `REVENUECAT_WEBHOOK_SECRET`: **必須**。未設定だと Webhook は 500 を返し、付与を拒否します

## 2. Edge Function デプロイ

**重要**: RevenueCat は `Authorization: Bearer <WEBHOOK_SECRET>` を送りますが、  
Supabase の既定ではこれを JWT とみなして弾きます（`UNAUTHORIZED_INVALID_JWT_FORMAT`）。  
そのため **Webhook 用 Function だけ JWT 検証をオフ**にしてデプロイします。

```bash
cd /path/to/surf

# Webhook のみ --no-verify-jwt（自前で WEBHOOK_SECRET を検証する）
supabase functions deploy revenuecat-webhook --no-verify-jwt

# アプリからの呼び出しは通常どおり JWT 必須
supabase functions deploy sync-subscription
supabase functions deploy delete-account
```

デプロイ後の確認:

```bash
# 不正シークレット → 401（自前検証）が正解
# 「Invalid JWT」なら --no-verify-jwt 未適用
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook" \
  -H "Authorization: Bearer wrong" \
  -H "Content-Type: application/json" \
  -d '{"event":{"type":"TEST","app_user_id":"$RCAnonymousID:x"}}'
```

## 3. RevenueCat Webhook 登録

RevenueCat → Project → Integrations → Webhooks

| 項目 | 値 |
|------|-----|
| URL | `https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook` |
| Authorization | `Bearer <REVENUECAT_WEBHOOK_SECRET>` |
| Events | INITIAL_PURCHASE, RENEWAL, CANCELLATION, EXPIRATION, PRODUCT_CHANGE, NON_RENEWING_PURCHASE など |

App User ID はアプリの `Purchases.logIn(users.user_id)` と一致していること。

## 4. DB マイグレーション

Supabase SQL Editor で順に実行:

1. （未適用なら）`migration_v1_24`〜`v1_27`
2. **必須** `migration_v1_28_ops_hardening.sql`

## 5. 動作確認

1. サンドボックスで Gear+ 購入 → `users.plan = gear_plus`
2. 24時間ギア＋購入 → `premium_override` が 24h、いいね無制限
3. 同じ txn で Webhook + sync が両方走ってもアイテムが二重にならない
4. `activate_timed_item('gear_plus_24h')` を qty=0 で呼ぶと `insufficient_quantity`
5. クライアントから `sync_subscription_plan` を直接叩くと権限エラー
6. Webhook に不正 Authorization → 401
