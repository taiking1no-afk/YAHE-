#!/usr/bin/env bash
# YAHE Android リリースビルド
#
# dart_defines.json を必ず --dart-define-from-file で注入してからビルドする。
#
# 背景: dart_defines.json はGradleプロジェクトに直接は紐付いておらず、
# `flutter build apk/appbundle --dart-define-from-file=...` を明示的に
# 実行しない限り SUPABASE_URL / SUPABASE_ANON_KEY 等が未注入のままになる。
# 未注入のReleaseビルドはSupabase初期化に失敗し、起動時の認証確認が
# 完了しないままアプリが使えなくなる（iOSで一度発生した既知の不具合と同種）。
#
# 使い方:
#   ./scripts/build_release_android.sh          # APK（実機への手動インストール・配布用）
#   ./scripts/build_release_android.sh apk       # 同上
#   ./scripts/build_release_android.sh appbundle # AAB（Google Play提出用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-apk}"
if [[ "$TARGET" != "apk" && "$TARGET" != "appbundle" ]]; then
  echo "❌ 不明なビルド種別: $TARGET （apk か appbundle を指定してください）"
  exit 1
fi

if [[ ! -f dart_defines.json ]]; then
  echo "❌ dart_defines.json がありません（dart_defines.json.example をコピーして本番の値を入れてください）"
  exit 1
fi

MISSING=$(python3 - <<'PY'
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
  echo "   起動時の認証確認が終わらずアプリが使えなくなります。"
  exit 1
fi
echo "✅ dart_defines.json: 必須キーはすべて揃っています"

echo "== flutter build $TARGET --release --dart-define-from-file=dart_defines.json =="
flutter build "$TARGET" --release --dart-define-from-file=dart_defines.json

echo ""
if [[ "$TARGET" == "apk" ]]; then
  echo "✅ build/app/outputs/flutter-apk/app-release.apk を実機に転送してインストールしてください"
  echo "   adb install -r build/app/outputs/flutter-apk/app-release.apk"
else
  echo "✅ build/app/outputs/bundle/release/app-release.aab を Google Play Console にアップロードしてください"
fi
