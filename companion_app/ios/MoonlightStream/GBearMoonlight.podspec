Pod::Spec.new do |s|
  s.name             = 'GBearMoonlight'
  s.version          = '1.0.0'
  s.summary          = 'Moonlight streaming core for the GBear companion iOS app'
  s.homepage         = 'https://github.com/moonlight-stream/moonlight-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = 'GBear Mac'
  s.platform         = :ios, '12.0'
  s.source           = { :path => '.' }

  moonlight_ios = File.expand_path('../../../Vendor/streaming-repos/moonlight-ios', __dir__)

  s.prepare_command = <<-CMD
    set -e
    bash "#{__dir__}/sync_sources.sh"
    bash "#{__dir__}/stage_vendor_libs.sh"
    bash "#{__dir__}/stage_ffmpeg_stubs.sh"
    bash "#{File.expand_path('../../../Scripts/build-moonlight-common-ios.sh', __dir__)}"
  CMD

  s.source_files = [
    'Sources/Limelight/**/*.{h,m,c}',
    'GBearSupport/**/*.{h,m}',
  ]
  s.preserve_paths = 'Sources/moonlight-common-c/**/*'
  s.public_header_files = [
    'GBearSupport/*.h',
    'Sources/Limelight/ViewControllers/StreamFrameViewController.h',
    'Sources/Limelight/Stream/StreamConfiguration.h',
  ]
  s.exclude_files = [
    'Sources/Limelight/**/Host+*.m',
    'Sources/Limelight/**/App+*.m',
    'Sources/Limelight/**/Settings+*.m',
    'GBearSupport/GBearTemporaryHost.m',
    'GBearSupport/GBearTemporaryHost.h',
  ]
  s.prefix_header_file = 'GBear-Limelight-Prefix.pch'
  s.vendored_frameworks = 'Vendor/moonlight-common.xcframework'
  s.static_framework = true

  force_load_libs = lambda do |sdk_dir|
    %w[gbear-ffmpeg-stubs SDL2 opus avcodec avformat avutil].map { |name|
      path = File.expand_path("Vendor/prebuilt/lib#{name}-#{sdk_dir}.a", __dir__)
      "-force_load \"#{path}\""
    }.join(' ')
  end
  device_libs = force_load_libs.call('iOS')
  sim_libs = force_load_libs.call('iOS-Sim')
  linker_flags = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' => "$(inherited) #{device_libs}",
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => "$(inherited) #{sim_libs}",
  }
  s.swift_version = '5.0'
  s.dependency 'OpenSSL-Universal'

  s.frameworks = %w[
    AVFoundation
    AVKit
    AudioToolbox
    CoreGraphics
    CoreBluetooth
    CoreHaptics
    CoreMotion
    Foundation
    GameController
    UIKit
    VideoToolbox
  ]
  s.libraries = %w[c++ xml2 z]

  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GBEAR_COMPANION=1',
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '"$(PODS_TARGET_SRCROOT)/Sources/moonlight-common-c"',
      '"$(PODS_TARGET_SRCROOT)/Sources/Limelight"',
      '"$(SDKROOT)/usr/include/libxml2"',
      "\"#{moonlight_ios}/libs/opus/include\"",
      "\"#{moonlight_ios}/libs/opus/include/opus\"",
      "\"#{moonlight_ios}/libs/SDL2/include\"",
      "\"#{moonlight_ios}/libs/FFmpeg/include\"",
    ].join(' '),
    'CLANG_ENABLE_MODULES' => 'YES',
  }.merge(linker_flags)

  # Runner also force-loads vendored libs (Debug); include FFmpeg stub there too.
  s.user_target_xcconfig = linker_flags
end
