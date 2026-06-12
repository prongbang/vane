#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vane_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vane_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Flutter bindings for the Vane HTTP/3 client.'
  s.description      = <<-DESC
Flutter bindings for the Vane HTTP/3 client backed by the shared Rust core.
                       DESC
  s.homepage         = 'https://github.com/inteniquetic/vane'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'INTENIQUETIC' => 'prongbang@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = [
    'vane_flutter/Sources/vane_flutter/**/*',
    '../../VaneSwift/Sources/VaneSwift/**/*.swift'
  ]
  s.vendored_frameworks = '../../VaneSwift/RustFramework.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.frameworks = 'SystemConfiguration'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'vane_flutter_privacy' => ['vane_flutter/Sources/vane_flutter/PrivacyInfo.xcprivacy']}
end
