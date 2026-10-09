require "ios/prepare_detector"
require "ios/swiftpm_grader_type"
require "ios/xcodebuild_grader_type"

module Ios
  extend Syrus::PluginApi

  syrus_plugin "ios" do
    description "iOS/Xcode grader support: typed xcodebuild and SwiftPM patterns with macOS capability requirements and isolated artifacts"
    long_description "iOS provides typed grader declarations for common macOS worker validation patterns: xcodebuild simulator tests with explicit schemes, destinations, DerivedData and xcresult bundles, plus Swift Package Manager build/test commands. It declares normal execution capabilities instead of adding platform-specific scheduler branches.\n\nUse it for iOS and Swift projects that run on native macOS workers with Xcode installed. Coding-mode iOS editor support is intentionally out of scope."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/ios.svg"
    author "Thomas Kadauke"
    category "language"
    prepare_priority 48

    suggests_enabling "iOS repositories get typed xcodebuild and SwiftPM graders with macOS/Xcode capability metadata and isolated build artifacts." do |signals|
      signals.repositories_detecting("ios")
    end

    provides prepare_detector: "Ios::PrepareDetector",
             grader_type: [ "Ios::XcodebuildGraderType", "Ios::SwiftpmGraderType" ]
  end
end
