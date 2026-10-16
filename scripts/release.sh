#!/bin/bash
#
# 构建 Release 版本、打包 zip，并在 GitHub 创建 Release（App 内「检查更新」依赖它）。
# 用法：scripts/release.sh [--draft]
#   版本号取自工程的 MARKETING_VERSION，发布说明取自 CHANGELOG.md 中对应版本的段落。
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="RoaycL/Scena"
DRAFT_FLAG=""
[[ "${1:-}" == "--draft" ]] && DRAFT_FLAG="--draft"

setting() {
    xcodebuild -project wallhaven.xcodeproj -scheme wallhaven -configuration Release -showBuildSettings 2>/dev/null \
        | sed -n "s/^ *$1 = //p" | head -1
}

VERSION="$(setting MARKETING_VERSION)"
TAG="v$VERSION"
echo "==> 版本 $VERSION"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "GitHub 上已经有 $TAG，请先在工程里提高 MARKETING_VERSION。" >&2
    exit 1
fi

echo "==> 构建 Release"
bash scripts/build-steam-service.sh
# generic 目标才会同时构建 Apple 芯片和 Intel；不指定时 xcodebuild 会选本机，只得到 arm64
xcodebuild -project wallhaven.xcodeproj -scheme wallhaven -configuration Release -destination 'generic/platform=macOS' build -quiet

# 产物位置由 Xcode 的 Locations 设置决定，从构建设置里读取
APP="$(setting CODESIGNING_FOLDER_PATH)"
[[ -d "$APP" ]] || { echo "找不到构建产物：$APP" >&2; exit 1; }

OUT="build/release"
mkdir -p "$OUT"
ZIP="$OUT/Scena-$VERSION.zip"
rm -f "$ZIP"
# ditto 会保留 .app 内的符号链接和权限
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/Scena")"
[[ "$ARCHS_BUILT" == *arm64* && "$ARCHS_BUILT" == *x86_64* ]] || { echo "安装包缺少架构：$ARCHS_BUILT" >&2; exit 1; }
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> 安装包 $ZIP（$(du -h "$ZIP" | cut -f1)）"

NOTES="$(awk -v v="## $VERSION" 'index($0, v) == 1 {found=1; next} found && /^## / {exit} found {print}' CHANGELOG.md)"
[[ -n "$NOTES" ]] || NOTES="Scena $VERSION"

read -r -p "在 $REPO 创建 $TAG${DRAFT_FLAG:+（草稿）}？[y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "已取消"; exit 0; }

gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Scena $VERSION" --notes "$NOTES" $DRAFT_FLAG
echo "==> 完成：https://github.com/$REPO/releases/tag/$TAG"
