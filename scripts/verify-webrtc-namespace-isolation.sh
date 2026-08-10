#!/usr/bin/env bash
set -euo pipefail

app_dir="${1:?usage: verify-webrtc-namespace-isolation.sh /path/to/Toj.app}"
frameworks_dir="${app_dir}/Frameworks"
toj_webrtc="${frameworks_dir}/WebRTC.framework/WebRTC"
livekit_webrtc="${frameworks_dir}/LiveKitWebRTC.framework/LiveKitWebRTC"
extension_dir="${app_dir}/PlugIns/TojBroadcastExtension.appex"

fail() {
  echo "WebRTC isolation check failed: $*" >&2
  exit 1
}

for path in "$toj_webrtc" "$livekit_webrtc" "${extension_dir}/TojBroadcastExtension"; do
  test -f "$path" || fail "missing built artifact: $path"
done

objc_classes() {
  xcrun nm -gU "$1" | awk '{
    symbol = $NF
    if (symbol ~ /^_OBJC_CLASS_\$_/) print symbol
  }' | LC_ALL=C sort -u
}

class_collisions="$(comm -12 <(objc_classes "$toj_webrtc") <(objc_classes "$livekit_webrtc"))"
test -z "$class_collisions" || fail "duplicate Objective-C classes: ${class_collisions}"

objc_classes "$toj_webrtc" | grep -Fxq '_OBJC_CLASS_$_RTCPeerConnection' \
  || fail "Toj WebRTC no longer exports RTCPeerConnection"
objc_classes "$livekit_webrtc" | grep -Fxq '_OBJC_CLASS_$_LKRTCPeerConnection' \
  || fail "LiveKit WebRTC no longer exports LKRTCPeerConnection"
if objc_classes "$toj_webrtc" | grep -Fxq '_OBJC_CLASS_$_LKRTCPeerConnection'; then
  fail "Toj WebRTC unexpectedly exports LiveKit-prefixed classes"
fi
if objc_classes "$livekit_webrtc" | grep -Fxq '_OBJC_CLASS_$_RTCPeerConnection'; then
  fail "LiveKit WebRTC unexpectedly exports unprefixed peer-connection classes"
fi

# Both pinned WebRTC builds contain the upstream UIDevice(RTCDevice) machineName category.
# Its implementation is intentionally treated as a reviewed compatibility exception. New
# Objective-C class collisions are rejected above; changing either binary requires re-reviewing
# this exact exception through the immutable artifact/package pins.
for binary in "$toj_webrtc" "$livekit_webrtc"; do
  category_dump="$(otool -ov "$binary")"
  grep -Fq 'RTCDevice' <<<"$category_dump" \
    || fail "reviewed RTCDevice category disappeared from $binary"
  grep -Fq 'machineName' <<<"$category_dump" \
    || fail "reviewed RTCDevice selector disappeared from $binary"
done

main_binary="${app_dir}/Toj"
test -f "$main_binary" || fail "missing Toj executable"
linked_libraries="$(otool -L "$main_binary")"
grep -Fq '@rpath/WebRTC.framework/WebRTC' <<<"$linked_libraries" \
  || fail "Toj executable is not linked to the attested 1:1 WebRTC runtime"
grep -Fq '@rpath/LiveKitWebRTC.framework/LiveKitWebRTC' <<<"$linked_libraries" \
  || fail "Toj executable is not linked to the group-call WebRTC runtime"

symbols_file="$(mktemp)"
trap 'rm -f "$symbols_file"' EXIT
xcrun nm "$main_binary" | xcrun swift-demangle > "$symbols_file"
grep -Fq 'Toj.WebRTCCallEngine' "$symbols_file" \
  || fail "release binary does not contain WebRTCCallEngine"
grep -Fq 'Toj.LiveKitGroupCallEngine' "$symbols_file" \
  || fail "release binary does not contain LiveKitGroupCallEngine"

test "$(plutil -extract CFBundleIdentifier raw "${extension_dir}/Info.plist")" \
  = 'com.toj.Toj.broadcast' || fail "unexpected broadcast-extension bundle identifier"
test "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "${extension_dir}/Info.plist")" \
  = 'com.apple.broadcast-services-upload' || fail "unexpected ReplayKit extension point"
test "$(plutil -extract RTCAppGroupIdentifier raw "${app_dir}/Info.plist")" \
  = 'group.com.toj.Toj' || fail "unexpected app-group identifier"
test "$(plutil -extract RTCScreenSharingExtension raw "${app_dir}/Info.plist")" \
  = 'com.toj.Toj.broadcast' || fail "unexpected screen-sharing extension identifier"

echo "WebRTC namespaces, release engines, and ReplayKit extension verified"
