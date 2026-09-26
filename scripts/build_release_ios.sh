#!/usr/bin/env bash
# YAHE iOS リリースビルド前準備
#
# dart_defines.json の値を Generated.xcconfig に正しく反映してから
# Xcode で Archive できる状態にする。
#
# 背景: dart_defines.json は Xcode プロジェクトに直接は紐付いておらず、
# `flutter build ios --dart-define-from-file=...` を実行して初めて
# ios/Flutter/Generated.xcconfig が更新される。この手順を踏まずに
# Xcode で直接 Archive すると、古い(または不足した) dart-define が
# 使われたバイナリが出来上がってしまう。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REQUIRED_KEYS=(
  SUPABASE_URL
  SUPABASE_ANON_KEY
  ADMOB_IOS_APP_ID
  ADMOB_ANDROID_APP_ID
  ADMOB_IOS_BANNER_ID
  ADMOB_ANDROID_BANNER_ID
  REVENUECAT_IOS_KEY
  REVENUECAT_ANDROID_KEY
)

if [[ ! -f dart_defines.json ]]; then
  echo "❌ dart_defines.json がありません（dart_defines.json.example をコピーして本番の値を入れてください）"
  exit 1
fi

MISSING=$(python3 - "$@" <<'PY'
import json
required = [
    "SUPABASE_URL", "SUPABASE_ANON_KEY",
    "ADMOB_IOS_APP_ID", "ADMOB_ANDROID_APP_ID",
    "ADMOB_IOS_BANNER_ID", "ADMOB_ANDROID_BANNER_ID",
    "REVENUECAT_IOS_KEY", "REVENUECAT_ANDROID_KEY",
]
with open("dart_defines.json") as f:
    data = json.load(f)
missing = [k for k in required if not data.get(k)]
print(",".join(missing))
PY
)

if [[ -n "$MISSING" ]]; then
  echo "❌ dart_defines.json に不足しているキーがあります: $MISSING"
  echo "   これらが未設定のまま Release ビルドすると、Supabase 初期化が失敗し"
  echo "   スプラッシュ画面から進めなくなります（Guideline 2.1 リジェクトの原因）。"
  exit 1
fi
echo "✅ dart_defines.json: 必須キーはすべて揃っています"

echo "== flutter build ios --release --dart-define-from-file=dart_defines.json =="
flutter build ios --release --dart-define-from-file=dart_defines.json

echo ""
echo "✅ ios/Flutter/Generated.xcconfig を最新の dart_defines.json で更新しました"
echo "次の手順:"
echo "  1) open ios/Runner.xcworkspace"
echo "  2) Xcode で Product > Archive"
echo "  3) Organizer から App Store Connect に配布"
