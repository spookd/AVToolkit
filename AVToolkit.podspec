Pod::Spec.new do |s|
  s.name         =  "AVToolkit"
  s.version      =  "0.0.1"
  s.summary      =  "A simple set of classes making it easier to deal with audio/video on iOS 6+."
  s.homepage     =  "https://github.com/spookd/AVToolkit"
  s.author       =  { "Nicolai Persson" => "recognize@me.com" }
  s.source       =  { :git => "https://github.com/spookd/AVToolkit.git", :tag => "v#{s.version}" }
  s.license      =  "Apache License, Version 2.0"

  # Platform setup
  s.requires_arc = true
  s.platform     = :ios, "6.0"

  # Frameworks
  s.frameworks   = "MediaPlayer", "AudioToolbox", "AVFoundation", "CoreFoundation", "CoreTelephony"
  
  # Dependencies
  s.dependency "Reachability", "~> 3.1.1"

  s.source_files = "AVToolkit/AVToolkit.h", "AVToolkit/Classes"

  # Build resources
  s.prepare_command = "xcodebuild -project AVToolkit.xcodeproj -target AVToolkitResources CONFIGURATION_BUILD_DIR=Resources 2>&1 > /dev/null"
  s.resource        = "Resources/AVToolkitResources.bundle"
end
