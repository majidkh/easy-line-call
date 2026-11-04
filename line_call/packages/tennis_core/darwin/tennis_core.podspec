#
# muse2 tennis core (C++17, zero third-party deps) + its Core ML ball
# detector, compiled into the app for the line-calling FFI bindings.
#
Pod::Spec.new do |s|
  s.name             = 'tennis_core'
  s.version          = '1.0.0'
  s.summary          = 'muse2 court calibration, ball tracking and bounce calls.'
  s.description      = 'Vendored muse2 core (see VENDORED.md) exposed over a C ABI.'
  s.homepage         = 'https://github.com/'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'SetMatch' => 'dev@setmatch.app' }
  s.source           = { :path => '.' }

  s.source_files        = 'Classes/**/*.{h,hpp,cpp,mm}'
  s.public_header_files = 'Classes/include/tennis/tennis_c.h', 'Classes/setmatch_shim.h'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '13.0'
  s.frameworks = 'CoreML', 'Foundation'
  s.library    = 'c++'
  # infer_apple.mm uses manual retain/release.
  s.requires_arc = false

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/Classes/include" "$(PODS_TARGET_SRCROOT)/Classes"',
    'GCC_OPTIMIZATION_LEVEL' => '2',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
