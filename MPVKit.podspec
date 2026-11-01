# libmpv for tvOS with Streamyfin's vo_avfoundation output (HDR and Dolby Vision
# through AVSampleBufferDisplayLayer), as Streamyfin's own app uses it.
Pod::Spec.new do |s|
  s.name             = 'MPVKit'
  s.version          = '0.41.0-av5'
  s.summary          = 'libmpv, FFmpeg and their dependencies for iOS and tvOS, with vo_avfoundation'
  s.homepage         = 'https://github.com/streamyfin/MPVKit'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'streamyfin' => 'https://github.com/streamyfin' }
  s.source           = { :http => 'https://github.com/streamyfin/MPVKit/releases/download/0.41.0-av5/MPVKit.xcframework.zip' }

  s.ios.deployment_target  = '13.0'
  s.tvos.deployment_target = '13.0'

  s.static_framework    = true
  s.vendored_frameworks = 'MPVKit.xcframework'
  s.frameworks = %w[AVFoundation AudioToolbox CoreAudio CoreFoundation CoreMedia CoreVideo Metal QuartzCore VideoToolbox CoreImage]
  s.libraries  = %w[bz2 iconv expat resolv xml2 z c++]
end
