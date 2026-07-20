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

# 3) 必須マイグレーションファイルの存在
for f in \
  supabase/migration_v1_8_security_hardening.sql \
  supabase/migration_v1_9_rls_full_hardening.sql \
  supabase/migration_v1_10_security_release.sql
do
  if [[ -f "$f" ]]; then ok "存在: $f"; else warn "不足: $f"; fi
done

# 4) Edge Functions
for f in \
  supabase/functions/delete-account/index.ts \
  supabase/functions/send-encounter-notification/index.ts
do
  if [[ -f "$f" ]]; then ok "存在: $f"; else warn "不足: $f"; fi
done

# 5) send-encounter-notification に本人確認があるか
if grep -n "callerUserId !== user_a_id\|caller mismatch" supabase/functions/send-encounter-notification/index.ts >/dev/null; then
  ok "send-encounter-notification: 呼び出し元本人確認あり"
else
  warn "send-encounter-notification: 本人確認ロジックが見つかりません"
fi

# 6) register_encounter RPC をクライアントが使っているか
if grep -n "register_encounter" lib/features/home/data/encounter_repository.dart >/dev/null; then
  ok "すれ違い登録は register_encounter RPC 経由"
else
  warn "encounter_repository が RPC を使っていません"
fi

# 7) 公開 URL 直リンクの残存（主要画面）
if grep -Rn "getPublicUrl\|Image\.network(vehicle\.photos" lib/features lib/shared 2>/dev/null; then
  warn "公開 URL 直表示の残存があります（SignedStorageImage へ置換推奨）"
else
  ok "主要 UI は SignedStorageImage 経由"
fi

echo ""
if [[ "$FAIL" -eq 1 ]]; then
  echo "結果: 要確認項目あり"
  exit 1
fi

echo "結果: ローカルチェック OK"
echo "次に Supabase SQL Editor で supabase/security_audit.sql を実行してください。"
