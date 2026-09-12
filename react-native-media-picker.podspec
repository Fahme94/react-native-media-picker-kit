require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-media-picker"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.license      = package["license"]
  s.authors      = { "Ahmed Fahmy" => "89461941+AhmedFahmeee@users.noreply.github.com" }
  s.homepage     = "https://github.com/Fahme94/react-native-media-picker"
  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/Fahme94/react-native-media-picker.git", :tag => "v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm}"

  # Objective-C++ translation units do not get Clang module auto-linking, so
  # every system framework the implementation touches has to be declared here
  # or the app fails at link time with undefined PHPicker/AVFoundation symbols.
  s.frameworks = "AVFoundation", "CoreMedia", "ImageIO", "Photos", "PhotosUI",
                 "UIKit", "UniformTypeIdentifiers"

  s.dependency "TOCropViewController", "~> 2.7"

  # Wires up React-Core, codegen output and the New Architecture flags.
  install_modules_dependencies(s)
end
