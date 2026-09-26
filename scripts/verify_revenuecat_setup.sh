#!/usr/bin/env bash
# YAHE RevenueCat / 課金設定の照合チェック
#
# 基本（ローカル照合のみ）:
#   bash scripts/verify_revenuecat_setup.sh
#
# Webhook 疎通まで（本物の秘密を渡す）:
#   export REVENUECAT_WEBHOOK_SECRET='afc9...（RC に貼った英数字）'
#   bash scripts/verify_revenuecat_setup.sh
#
# ※ 'RevenueCatダッシュボードに入れた同じ値' や 'sk_...' はプレースホルダです。そのまま使わないでください。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
WARN=0

ok()   { echo "✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "⚠️  $1"; WARN=$((WARN+1)); }
sec()  { echo ""; echo "── $1 ──"; }

# rg が無い環境（通常の macOS ターミナル）でも動くように grep にフォールバック
search_q() {
  local pattern="$1"; shift
  if command -v rg >/dev/null 2>&1; then
    rg -q -- "$pattern" "$@"
  else
    grep -R -q -- "$pattern" "$@" 2>/dev/null
  fi
}

contains_q() {
  local hay="$1"
  local needle="$2"
  case "$hay" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

EXPECTED_PRODUCTS=(
  yahe_pit_in_monthly
  yahe_gear_plus_monthly
  yahe_gear_r_monthly
  yahe_nitro_1h
  yahe_shibu_10
  yahe_super_nitro_1h
  yahe_geki_shibu_10
  yahe_gear_plus_24h
)

EXPECTED_ENTITLEMENTS=(pit_in gear_plus gear_r)

echo "== YAHE RevenueCat 設定照合 =="
echo "コード上の正: product_id 8種 / entitlement 3種"
echo ""

# プレースホルダ検知
if [[ -n "${REVENUECAT_WEBHOOK_SECRET:-}" ]]; then
  if contains_q "$REVENUECAT_WEBHOOK_SECRET" "ダッシュボード" \
    || contains_q "$REVENUECAT_WEBHOOK_SECRET" "同じ値" \
    || [[ "$REVENUECAT_WEBHOOK_SECRET" == "..." ]]; then
    bad "REVENUECAT_WEBHOOK_SECRET が説明文のままです。RC に貼った英数字の秘密を export してください"
    echo "  例: export REVENUECAT_WEBHOOK_SECRET='afc9dcf2...'"
    unset REVENUECAT_WEBHOOK_SECRET
  fi
fi
if [[ -n "${REVENUECAT_SECRET_API_KEY:-}" ]]; then
  if [[ "$REVENUECAT_SECRET_API_KEY" == "sk_..." ]] \
    || [[ "$REVENUECAT_SECRET_API_KEY" == "sk_" ]] \
    || contains_q "$REVENUECAT_SECRET_API_KEY" "Secret" \
    || contains_q "$REVENUECAT_SECRET_API_KEY" "..."; then
    warn "シェルに残っている REVENUECAT_SECRET_API_KEY がプレースホルダのため無視します（Webhook 確認には不要）"
    echo "    消す場合: unset REVENUECAT_SECRET_API_KEY"
    unset REVENUECAT_SECRET_API_KEY
  fi
fi

# ─────────────────────────────────────────────
sec "1) アプリ公開キー（dart_defines.json）"
# ─────────────────────────────────────────────
if [[ ! -f dart_defines.json ]]; then
  bad "dart_defines.json がありません（.example をコピーして本番キーを入れてください）"
else
  python3 - <<'PY'
import json, sys
d = json.load(open("dart_defines.json"))
ok = True
ios = d.get("REVENUECAT_IOS_KEY", "")
and_ = d.get("REVENUECAT_ANDROID_KEY", "")
def check(name, v, prefix):
    global ok
    if not v:
        print(f"BAD {name}: 未設定")
        ok = False
        return
    if not v.startswith(prefix):
        print(f"BAD {name}: 接頭辞が {prefix} ではありません（先頭={v[:8]!r}）")
        ok = False
        return
    if "XXXX" in v or "ここに" in v:
        print(f"BAD {name}: プレースホルダのままです")
        ok = False
        return
    if len(v) < 12:
        print(f"BAD {name}: 短すぎます")
        ok = False
        return
    print(f"OK {name}: {prefix}…（len={len(v)}）")
check("REVENUECAT_IOS_KEY", ios, "appl_")
check("REVENUECAT_ANDROID_KEY", and_, "goog_")
sys.exit(0 if ok else 1)
PY
  if [[ $? -eq 0 ]]; then ok "dart_defines.json の RC 公開キー形式は妥当"; else bad "dart_defines.json の RC キーを確認してください"; fi
fi

# ─────────────────────────────────────────────
sec "2) コード内 product_id / entitlement の一致"
# ─────────────────────────────────────────────
missing=0
for pid in "${EXPECTED_PRODUCTS[@]}"; do
  if search_q "$pid" lib; then
    :
  else
    echo "  missing in Dart: $pid"
    missing=1
  fi
done
if [[ $missing -eq 0 ]]; then
  ok "Dart 側に期待 product_id がすべて存在"
else
  bad "Dart 側に欠けている product_id があります"
fi

for ent in "${EXPECTED_ENTITLEMENTS[@]}"; do
  if search_q "$ent" lib/core/revenuecat lib/features/store; then
    :
  else
    warn "entitlement '$ent' の参照が少ない可能性"
  fi
done
ok "期待 entitlement: ${EXPECTED_ENTITLEMENTS[*]}"

edge_missing=0
for pid in yahe_nitro_1h yahe_shibu_10 yahe_super_nitro_1h yahe_geki_shibu_10 yahe_gear_plus_24h; do
  if ! search_q "$pid" supabase/functions/revenuecat-webhook/index.ts; then
    bad "webhook に $pid がありません"; edge_missing=1
  fi
  if ! search_q "$pid" supabase/functions/sync-subscription/index.ts; then
    bad "sync-subscription に $pid がありません"; edge_missing=1
  fi
done
if [[ $edge_missing -eq 0 ]]; then ok "Edge Function の消耗型 product_id はコードと一致"; fi

if search_q "REVENUECAT_WEBHOOK_SECRET is not set" supabase/functions/revenuecat-webhook/index.ts; then
  ok "Webhook は秘密未設定時に拒否する実装"
else
  bad "Webhook の秘密必須化が見つかりません"
fi

# ─────────────────────────────────────────────
sec "3) Supabase プロジェクト連携"
# ─────────────────────────────────────────────
PROJECT_REF=""
if [[ -f supabase/.temp/project-ref ]]; then
  PROJECT_REF="$(tr -d '[:space:]' < supabase/.temp/project-ref)"
  ok "linked project-ref: $PROJECT_REF"
else
  warn "supabase link されていません（supabase link 推奨）"
fi

SUPABASE_URL="${SUPABASE_URL:-}"
if [[ -z "$SUPABASE_URL" && -n "$PROJECT_REF" ]]; then
  SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
fi

# ─────────────────────────────────────────────
sec "4) Webhook エンドポイント疎通（任意）"
# ─────────────────────────────────────────────
if [[ -z "${REVENUECAT_WEBHOOK_SECRET:-}" ]]; then
  warn "REVENUECAT_WEBHOOK_SECRET 未設定 → 正しい秘密でのテストをスキップ"
  echo "    例: export REVENUECAT_WEBHOOK_SECRET='（RC Authorization の Bearer の後ろの英数字）'"
elif [[ -z "$SUPABASE_URL" ]]; then
  warn "SUPABASE_URL 不明 → Webhook テストをスキップ"
else
  WH_URL="${SUPABASE_URL}/functions/v1/revenuecat-webhook"
  echo "  URL: $WH_URL"

  code=$(curl -s -o /tmp/yahe_rc_wh_body.txt -w "%{http_code}" \
    -X POST "$WH_URL" \
    -H "Authorization: Bearer wrong-secret" \
    -H "Content-Type: application/json" \
    -d '{"event":{"type":"TEST","app_user_id":"00000000-0000-0000-0000-000000000000"}}' || true)
  body=$(cat /tmp/yahe_rc_wh_body.txt 2>/dev/null || true)
  if contains_q "$body" "Invalid JWT" || contains_q "$body" "INVALID_JWT"; then
    bad "Supabase が Authorization を JWT とみなして弾いています → supabase functions deploy revenuecat-webhook --no-verify-jwt"
  elif [[ "$code" == "401" ]]; then
    ok "不正 Authorization → 401（秘密検証が効いている）"
  elif [[ "$code" == "500" ]]; then
    if contains_q "$body" "misconfigured" || contains_q "$body" "not set"; then
      bad "サーバーに REVENUECAT_WEBHOOK_SECRET が未設定"
    else
      warn "不正トークンで HTTP $code: $body"
    fi
  else
    warn "不正トークンで HTTP $code（期待 401）: $body"
  fi

  code=$(curl -s -o /tmp/yahe_rc_wh_body.txt -w "%{http_code}" \
    -X POST "$WH_URL" \
    -H "Authorization: Bearer ${REVENUECAT_WEBHOOK_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{"event":{"type":"TEST","app_user_id":"$RCAnonymousID:test"}}' || true)
  body=$(cat /tmp/yahe_rc_wh_body.txt 2>/dev/null || true)
  if contains_q "$body" "Invalid JWT" || contains_q "$body" "INVALID_JWT"; then
    bad "正しい秘密でも JWT ゲートに弾かれています → --no-verify-jwt で再デプロイ"
  elif [[ "$code" == "200" ]]; then
    ok "正しい Authorization で到達（匿名は skipped）"
  else
    warn "正しい Authorization で HTTP $code: $body"
    echo "    → RC に貼った値と export した値が一致していない可能性が高いです"
  fi
fi

if [[ -n "$SUPABASE_URL" ]]; then
  WH_URL="${SUPABASE_URL}/functions/v1/revenuecat-webhook"
  code=$(curl -s -o /tmp/yahe_rc_wh_probe.txt -w "%{http_code}" \
    -X POST "$WH_URL" \
    -H "Authorization: Bearer not-a-jwt" \
    -H "Content-Type: application/json" \
    -d '{"event":{"type":"TEST","app_user_id":"$RCAnonymousID:x"}}' || true)
  body=$(cat /tmp/yahe_rc_wh_probe.txt 2>/dev/null || true)
  if contains_q "$body" "Invalid JWT" || contains_q "$body" "INVALID_JWT"; then
    bad "本番 Webhook が JWT 検証 ON のまま"
    echo "    修正: supabase functions deploy revenuecat-webhook --no-verify-jwt"
  elif [[ "$code" == "401" ]]; then
    ok "Webhook は JWT ゲートOFF相当（自前の秘密検証で 401）"
  elif [[ "$code" == "500" ]] && contains_q "$body" "misconfigured"; then
    ok "Webhook Function には到達（秘密未設定の 500）— secrets set が必要"
  elif [[ "$code" == "504" || "$code" == "502" || "$code" == "503" ]]; then
    warn "Webhook プローブが一時的に HTTP $code（再実行で問題なければ無視可）"
  else
    warn "Webhook プローブ HTTP $code: $body"
  fi
fi

# ─────────────────────────────────────────────
sec "5) RevenueCat Secret API（任意）"
# ─────────────────────────────────────────────
if [[ -z "${REVENUECAT_SECRET_API_KEY:-}" ]]; then
  warn "REVENUECAT_SECRET_API_KEY 未設定 → RC API 照合をスキップ（必須ではない）"
  echo "    必要なら: RevenueCat → Project settings → API keys → Secret key"
else
  api_code=$(curl -s -o /tmp/yahe_rc_api.txt -w "%{http_code}" \
    -H "Authorization: Bearer ${REVENUECAT_SECRET_API_KEY}" \
    -H "Content-Type: application/json" \
    "https://api.revenuecat.com/v1/subscribers/yahe_setup_probe_nonexistent" || true)
  if [[ "$api_code" == "404" || "$api_code" == "200" ]]; then
    ok "REVENUECAT_SECRET_API_KEY は API に通る（HTTP $api_code）"
  elif [[ "$api_code" == "401" || "$api_code" == "403" ]]; then
    bad "REVENUECAT_SECRET_API_KEY が拒否されました（HTTP $api_code）"
  else
    warn "RC API HTTP $api_code: $(head -c 200 /tmp/yahe_rc_api.txt 2>/dev/null || true)"
  fi
fi

# ─────────────────────────────────────────────
sec "6) ダッシュボード目視チェックリスト（手動）"
# ─────────────────────────────────────────────
cat <<'EOF'
RevenueCat Dashboard で確認:
  Entitlements: pit_in / gear_plus / gear_r
  Products: yahe_pit_in_monthly, yahe_gear_plus_monthly, yahe_gear_r_monthly,
            yahe_nitro_1h, yahe_shibu_10, yahe_super_nitro_1h,
            yahe_geki_shibu_10, yahe_gear_plus_24h
  Webhooks URL: https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook
  Authorization: Bearer <英数字の秘密>
EOF

echo ""
echo "════════════════════════════════"
echo "結果: OK=$PASS  WARN=$WARN  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "失敗あり — 上記 ❌ を先に直してください"
  exit 1
fi
echo "ローカル照合は問題なし。"
echo "正しい秘密で疎通する例:"
echo "  export REVENUECAT_WEBHOOK_SECRET='（RC に貼った英数字だけ）'"
echo "  bash scripts/verify_revenuecat_setup.sh"
