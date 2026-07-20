#!/bin/bash
# iCloud Desktop 上のプロジェクトで com.apple.provenance が付与され codesign が失敗するのを防ぐ。
set -euo pipefail

PROJECT_ROOT="${SRCROOT}/.."
SAFE_BUILD="/tmp/surf-flutter-build-${USER:-build}"

if [[ ! -L "${PROJECT_ROOT}/build" ]]; then
  rm -rf "${PROJECT_ROOT}/build"
  mkdir -p "${SAFE_BUILD}"
  ln -s "${SAFE_BUILD}" "${PROJECT_ROOT}/build"
fi

xattr -cr "${PROJECT_ROOT}" 2>/dev/null || true

/bin/sh "${FLUTTER_ROOT}/packages/flutter_tools/bin/xcode_backend.sh" build
