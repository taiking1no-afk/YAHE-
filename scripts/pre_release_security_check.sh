#!/usr/bin/env bash
# YAHE リリース前ローカルセキュリティチェック
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== YAHE pre-release security check =="
FAIL=0

warn() { echo "⚠️  $1"; FAIL=1; }
ok() { echo "✅ $1"; }

# 1) service_role / secret がアプリコードに入っていないか
if find lib -name '*.dart' -print0 2>/dev/null | xargs -0 grep -l "SERVICE_ROLE_KEY" 2>/dev/null | grep -q .; then
  warn "service_role キーが Flutter クライアント(lib/)に含まれています"
else
  ok "Flutter クライアント(lib/)に service_role キーなし"
fi

# 2) ハードコードされた Supabase anon key（Release 用 default）が main config に残っていないか
if grep -n "defaultValue: 'eyJ" lib/core/supabase/supabase_config.dart 2>/dev/null; then
  warn "supabase_config に Release 向け default anon key があります（dev fallback のみに限定してください）"
else
  ok "Release 用 anon key の直書き default なし"
fi

# 3) 必須マイグレーション
for f in \
  supabase/migration_v1_8_security_hardening.sql \
  supabase/migration_v1_9_rls_full_hardening.sql \
  supabase/migration_v1_10_security_release.sql \
  supabase/migration_v1_27_security_and_spec_fixes.sql \
  supabase/migration_v1_28_ops_hardening.sql
do
  if [[ -f "$f" ]]; then ok "存在: $f"; else warn "不足: $f"; fi
done

# 4) Edge Functions
for f in \
  supabase/functions/delete-account/index.ts \
  supabase/functions/send-encounter-notification/index.ts \
  supabase/functions/revenuecat-webhook/index.ts \
  supabase/functions/sync-subscription/index.ts
do
  if [[ -f "$f" ]]; then ok "存在: $f"; else warn "不足: $f"; fi
done

# 5) Webhook 秘密が必須化されているか
if grep -n "REVENUECAT_WEBHOOK_SECRET is not set\|server misconfigured" supabase/functions/revenuecat-webhook/index.ts >/dev/null; then
  ok "revenuecat-webhook: 秘密未設定時は拒否"
else
  warn "revenuecat-webhook: 秘密必須化ロジックが見つかりません"
fi

# 6) 消耗型の原子的付与
if grep -n "fulfill_consumable_purchase" supabase/functions/revenuecat-webhook/index.ts >/dev/null \
  && grep -n "fulfill_consumable_purchase" supabase/functions/sync-subscription/index.ts >/dev/null; then
  ok "消耗型は fulfill_consumable_purchase 経由"
else
  warn "消耗型の冪等付与が見つかりません"
fi

# 7) iOS production push entitlements
if [[ -f ios/Runner/RunnerRelease.entitlements ]] \
  && grep -q "production" ios/Runner/RunnerRelease.entitlements; then
  ok "iOS Release entitlements: aps-environment=production"
else
  warn "RunnerRelease.entitlements (production) がありません"
fi

# 8) ホーム長押しデバッグが kDebugMode 限定か
if grep -n "onLongPress: kDebugMode" lib/features/home/presentation/home_screen.dart >/dev/null; then
  ok "ホーム長押しデバッグは kDebugMode 限定"
else
  warn "ホーム長押しデバッグが本番でも有効の可能性"
fi

# 9) send-encounter-notification に本人確認があるか
if grep -n "callerUserId !== user_a_id\|caller mismatch" supabase/functions/send-encounter-notification/index.ts >/dev/null; then
  ok "send-encounter-notification: 呼び出し元本人確認あり"
else
  warn "send-encounter-notification: 本人確認ロジックが見つかりません"
fi

# 10) register_encounter RPC
if grep -n "register_encounter" lib/features/home/data/encounter_repository.dart >/dev/null; then
  ok "すれ違い登録は register_encounter RPC 経由"
else
  warn "encounter_repository が RPC を使っていません"
fi

echo ""
if [[ "$FAIL" -eq 1 ]]; then
  echo "結果: 要確認項目あり"
  exit 1
fi

echo "結果: ローカルチェック OK"
echo "次:"
echo "  1) Supabase SQL Editor で migration_v1_28_ops_hardening.sql を実行"
echo "  2) WEBHOOK_SETUP.md に従い Secrets / Functions / Webhook を設定"
echo "  3) scripts/owner_ops_gate.md のストア作業を完了"
echo "  4) security_audit.sql / TestFlight QA"
