# LibSignalClient is CocoaPods-only (upstream: SPM unsupported; prebuilt FFI, no Rust needed).
# Checksum = SHA-256 of libsignal-client-ios-build-v0.96.4.tar.gz, verified against BOTH the
# GitHub release asset .sha256 and Signal-iOS's own Podfile pin (2026-07-03).
platform :ios, '26.0'
use_frameworks!

ENV['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'] = 'afac333d0ee6dd86786316bb8346d8dd61ca153afb5080362a35553a701efa4f'

target 'Toj' do
  pod 'LibSignalClient', git: 'https://github.com/signalapp/libsignal.git', tag: 'v0.96.4'
  pod 'GRDB.swift/SQLCipher'

  target 'TojTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
      # libsignal_ffi.a embeds BoringSSL (C++); a pure-Swift host must link libc++
      # explicitly or the framework fails with undefined std::/__cxa_ symbols.
      if t.name == 'LibSignalClient'
        c.build_settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lc++']
      end
    end
  end
end
