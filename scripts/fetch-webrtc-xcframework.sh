#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVISION="$(tr -d '[:space:]' < "$ROOT/Dependencies/TojWebRTC/REVISION")"
TAG="webrtc-${REVISION:0:12}"
REPOSITORY="${TOJ_WEBRTC_REPOSITORY:-mmarufov/tojmessanger}"
DEST="$ROOT/Dependencies/TojWebRTC"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/toj-webrtc.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "TOJ_WEBRTC_REPOSITORY must be in owner/repository form" >&2
  exit 2
fi

gh release download "$TAG" \
  --repo "$REPOSITORY" \
  --pattern 'WebRTC.xcframework.zip' \
  --pattern 'WebRTC.xcframework.zip.sha256' \
  --pattern 'REVISION' \
  --pattern 'BUILD_SOURCE_REF' \
  --dir "$TMP"

if ! cmp -s "$DEST/REVISION" "$TMP/REVISION"; then
  echo "Release revision does not match the repository pin" >&2
  exit 3
fi

if [[ "$(wc -l < "$TMP/BUILD_SOURCE_REF" | tr -d ' ')" != "1" ]]; then
  echo "Release build source reference has an invalid format" >&2
  exit 3
fi
BUILD_SOURCE_REF="$(tr -d '\n' < "$TMP/BUILD_SOURCE_REF")"
if [[ "$BUILD_SOURCE_REF" != "refs/tags/$TAG" && \
      ! "$BUILD_SOURCE_REF" =~ ^refs/tags/${TAG}-build\.[1-9][0-9]*$ ]]; then
  echo "Release build source is not an approved immutable tag" >&2
  exit 3
fi

if [[ "${TOJ_WEBRTC_ALLOW_UNATTESTED:-0}" == "1" ]]; then
  if [[ -n "${CI:-}" && "${CI}" != "0" && "${CI}" != "false" ]]; then
    echo "CI may not bypass WebRTC artifact attestation" >&2
    exit 2
  fi
  echo "WARNING: installing WebRTC without provenance verification for local development" >&2
else
  if ! gh attestation verify --help >/dev/null 2>&1; then
    echo "A GitHub CLI with 'gh attestation verify' support is required" >&2
    echo "Upgrade gh, or set TOJ_WEBRTC_ALLOW_UNATTESTED=1 only for a local, non-release build" >&2
    exit 2
  fi
  gh attestation verify "$TMP/WebRTC.xcframework.zip" \
    --repo "$REPOSITORY" \
    --signer-workflow "$REPOSITORY/.github/workflows/webrtc-xcframework.yml" \
    --source-ref "$BUILD_SOURCE_REF" \
    --deny-self-hosted-runners
fi

if ! grep -Eq '^[0-9a-f]{64}  WebRTC\.xcframework\.zip$' \
  "$TMP/WebRTC.xcframework.zip.sha256" || \
  [[ "$(wc -l < "$TMP/WebRTC.xcframework.zip.sha256" | tr -d ' ')" != "1" ]]; then
  echo "WebRTC checksum sidecar has an invalid format" >&2
  exit 3
fi

(
  cd "$TMP"
  shasum -a 256 -c WebRTC.xcframework.zip.sha256
)

ARCHIVE_ENTRIES="$(unzip -Z1 "$TMP/WebRTC.xcframework.zip")"
if grep -Eq '(^/|(^|/)\.\.(/|$)|\\)' <<< "$ARCHIVE_ENTRIES"; then
  echo "WebRTC archive contains an unsafe path" >&2
  exit 3
fi
if ! grep -q '^WebRTC\.xcframework/Info\.plist$' <<< "$ARCHIVE_ENTRIES"; then
  echo "WebRTC archive does not contain the expected XCFramework" >&2
  exit 3
fi

STAGED="$TMP/staged"
mkdir -p "$STAGED"
ditto -x -k "$TMP/WebRTC.xcframework.zip" "$STAGED"
if find "$STAGED/WebRTC.xcframework" -type l -print -quit | grep -q .; then
  echo "WebRTC archive contains a symbolic link" >&2
  exit 3
fi
plutil -lint "$STAGED/WebRTC.xcframework/Info.plist" >/dev/null

rm -rf "$DEST/WebRTC.xcframework"
mv "$STAGED/WebRTC.xcframework" "$DEST/WebRTC.xcframework"
echo "Installed WebRTC $REVISION into $DEST/WebRTC.xcframework"
