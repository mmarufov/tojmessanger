Pod::Spec.new do |spec|
  spec.name = 'TojWebRTC'
  spec.version = '1.0.0'
  spec.summary = 'Pinned WebRTC XCFramework built from upstream for Toj voice calls.'
  spec.homepage = 'https://webrtc.org/'
  spec.license = { type: 'BSD', file: 'LICENSE' }
  spec.author = { 'Toj' => 'engineering@toj.app' }
  spec.platform = :ios, '26.0'
  spec.source = { path: '.' }
  spec.vendored_frameworks = 'WebRTC.xcframework'
  spec.preserve_paths = [
    'REVISION',
    'DEPOT_TOOLS_REVISION',
    'LICENSE',
    'README.md',
    'SBOM.spdx.json',
    'WebRTC.xcframework'
  ]
end
