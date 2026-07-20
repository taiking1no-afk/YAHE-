#!/usr/bin/env bash
# Desktop + iCloud 環境で Pods が空になる問題の応急復旧スクリプト
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_PODS="/tmp/surf-pod-install/ios/Pods"
IOS_PODS="$ROOT/ios/Pods"

export COPYFILE_DISABLE=1

if [ ! -d "$TMP_PODS/FirebaseInstallations/FirebaseInstallations" ]; then
  echo "バックアップが見つかりません: $TMP_PODS"
  echo "次を実行してから再試行してください:"
  echo "  mkdir -p /tmp/surf-pod-install"
  echo "  rsync -a --exclude build --exclude .dart_tool \"$ROOT/\" /tmp/surf-pod-install/"
  echo "  cd /tmp/surf-pod-install && flutter pub get && cd ios && pod install"
  exit 1
fi

repair_pod() {
  local name="$1"
  local src="$TMP_PODS/$name"
  local dst="$IOS_PODS/$name"
  if [ ! -d "$src" ]; then
    return
  fi
  local src_count dst_count
  src_count=$(find "$src" -type f ! -name LICENSE ! -name README.md 2>/dev/null | wc -l | tr -d ' ')
  dst_count=$(find "$dst" -type f ! -name LICENSE ! -name README.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dst_count" -lt "$src_count" ] && [ "$src_count" -gt 2 ]; then
    echo "復旧: $name ($dst_count -> $src_count files)"
    rm -rf "$dst"
    cp -R "$src" "$dst"
    xattr -cr "$dst" 2>/dev/null || true
  fi
}

cd "$ROOT/ios"
for pod in "$TMP_PODS"/*; do
  repair_pod "$(basename "$pod")"
done

echo "完了。Xcode で Product > Clean Build Folder 後に Run してください。"
