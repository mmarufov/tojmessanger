#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVISION_FILE="$ROOT/Dependencies/TojWebRTC/REVISION"
REVISION="${TOJ_WEBRTC_REVISION:-$(tr -d '[:space:]' < "$REVISION_FILE")}"
DEPOT_TOOLS_REVISION_FILE="$ROOT/Dependencies/TojWebRTC/DEPOT_TOOLS_REVISION"
DEPOT_TOOLS_REVISION="${TOJ_DEPOT_TOOLS_REVISION:-$(tr -d '[:space:]' < "$DEPOT_TOOLS_REVISION_FILE")}"
BUILD_ROOT="${TOJ_WEBRTC_BUILD_ROOT:-$ROOT/.webrtc-build}"
DEPOT_TOOLS="$BUILD_ROOT/depot_tools"
CHECKOUT_PARENT="$BUILD_ROOT/checkout"
SOURCE="$CHECKOUT_PARENT/src"
OUTPUT="$ROOT/Dependencies/TojWebRTC/WebRTC.xcframework"

if [[ ! "$REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "REVISION must be a full 40-character upstream WebRTC commit" >&2
  exit 2
fi
if [[ ! "$DEPOT_TOOLS_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "DEPOT_TOOLS_REVISION must be a full 40-character commit" >&2
  exit 2
fi

mkdir -p "$BUILD_ROOT" "$CHECKOUT_PARENT"

if [[ ! -d "$DEPOT_TOOLS/.git" ]]; then
  git clone --no-checkout https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
fi
git -C "$DEPOT_TOOLS" fetch --no-tags origin "$DEPOT_TOOLS_REVISION"
git -C "$DEPOT_TOOLS" checkout --detach "$DEPOT_TOOLS_REVISION"
test "$(git -C "$DEPOT_TOOLS" rev-parse HEAD)" = "$DEPOT_TOOLS_REVISION"
export PATH="$DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0

if [[ ! -d "$SOURCE/.git" ]]; then
  (
    cd "$CHECKOUT_PARENT"
    fetch --nohooks webrtc_ios
  )
fi

(
  cd "$SOURCE"
  git fetch --no-tags origin "$REVISION"
  gclient sync -D --no-history --revision "src@$REVISION"
  git checkout --detach "$REVISION"
  test "$(git rev-parse HEAD)" = "$REVISION"

  vpython3 tools_webrtc/ios/build_ios_libs.py \
    --build_config release \
    --deployment-target 26.0 \
    --arch device:arm64 simulator:arm64 simulator:x64 \
    --output-dir "$SOURCE/out/toj_ios_libs"
)

rm -rf "$OUTPUT"
ditto "$SOURCE/out/toj_ios_libs/WebRTC.xcframework" "$OUTPUT"

ARCHIVE="$ROOT/Dependencies/TojWebRTC/WebRTC.xcframework.zip"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT" "$ARCHIVE"
(
  cd "$(dirname "$ARCHIVE")"
  shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)

echo "Built WebRTC $REVISION"
echo "Artifact: $ARCHIVE"
echo "Checksum: $(cut -d ' ' -f 1 "$ARCHIVE.sha256")"
