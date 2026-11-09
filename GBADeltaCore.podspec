Pod::Spec.new do |spec|
  spec.name         = "GBADeltaCore"
  spec.version      = "0.1"
  spec.summary      = "Game Boy Advance plug-in for Delta emulator."
  spec.description  = "iOS framework that wraps VBA-M to allow playing Game Boy Advance games with Delta emulator."
  spec.homepage     = "https://github.com/rileytestut/GBADeltaCore"
  spec.platform     = :ios, "15.5"
  spec.source       = { :git => "https://github.com/rileytestut/GBADeltaCore.git" }

  spec.author             = { "Riley Testut" => "riley@rileytestut.com" }
  spec.social_media_url   = "https://twitter.com/rileytestut"
  
  spec.source_files  = "GBADeltaCore/**/*.{h,m,mm,swift}", "visualboyadvance-m/src/core/base/*.h", "visualboyadvance-m/src/core/base/internal/*.h", "visualboyadvance-m/src/core/gba/*.h", "visualboyadvance-m/src/core/gba/internal/*.h", "visualboyadvance-m/src/core/gb/*.h", "visualboyadvance-m/src/core/apu/*.h"
  spec.public_header_files = "GBADeltaCore/Types/GBATypes.h", "GBADeltaCore/Bridge/GBAEmulatorBridge.h", "GBADeltaCore/GBADeltaCore.h"
  spec.header_mappings_dir = ""
  spec.resource_bundles = {
    "GBADeltaCore" => ["GBADeltaCore/**/*.deltamapping", "GBADeltaCore/**/*.deltaskin", "visualboyadvance-m/src/vba-over.ini"]
  }
  
  spec.dependency 'DeltaCore'
  
  spec.xcconfig = {
    "HEADER_SEARCH_PATHS" => '"${PODS_CONFIGURATION_BUILD_DIR}" "$(PODS_ROOT)/Headers/Private/GBADeltaCore/visualboyadvance-m/third_party/include" "$(PODS_ROOT)/Headers/Private/GBADeltaCore/visualboyadvance-m/third_party/include/stb"',
    "USER_HEADER_SEARCH_PATHS" => '"$(PODS_ROOT)/Headers/Private/GBADeltaCore/visualboyadvance-m/src" "$(PODS_ROOT)/Headers/Private/GBADeltaCore/visualboyadvance-m/src/core/fex" "$(PODS_ROOT)/Headers/Private/GBADeltaCore/GBADeltaCore/Generated"',
    "GCC_PREPROCESSOR_DEFINITIONS" => "STATIC_LIBRARY=1"
  }
  
end
