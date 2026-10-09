require "rails_helper"

RSpec.describe Ios::XcodebuildGraderType do
  it "registers the xcodebuild type name" do
    expect(described_class.type_name).to eq("xcodebuild")
  end

  it "expands to a capability-aware xcodebuild simulator grader" do
    step = described_class.grade_steps(
      config: {
        "workspace" => "MobileApp.xcworkspace",
        "scheme" => "MobileApp",
        "junit_output" => true
      },
      default_failures: "strict"
    ).first

    expect(step).to have_attributes(
      name: "ios-tests",
      display_name: "iOS simulator tests",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 45,
      junit_output: "build/syrus/junit/ios-tests.xml"
    )
    expect(step.run).to include("xcodebuild test")
    expect(step.run).to include("-workspace MobileApp.xcworkspace")
    expect(step.run).to include("-scheme MobileApp")
    expect(step.run).to include("-destination platform\\=iOS\\ Simulator,name\\=iPhone\\ 16,OS\\=latest")
    expect(step.run).to include("-derivedDataPath .syrus/DerivedData/ios-tests")
    expect(step.run).to include("-resultBundlePath build/syrus/ios-tests.xcresult")
    expect(step.run).to include("CODE_SIGNING_ALLOWED\\=NO")
    expect(step.capabilities.to_h).to eq(
      "os" => [ "macos" ],
      "arch" => [ "arm64" ],
      "toolchain" => [ "xcode" ],
      "runtime" => [ "ios_simulator" ]
    )
    expect(step.metadata["artifact_outputs"]).to include(
      { "artifact" => "build/syrus/ios-tests.xcresult", "format" => "xcresult" },
      { "artifact" => ".syrus/DerivedData/ios-tests", "format" => "derived_data" }
    )
    expect(step.metadata["result_outputs"]).to eq([
      { "artifact" => "build/syrus/junit/ios-tests.xml", "format" => "junit" }
    ])
    expect(step.metadata.dig("filter_capabilities", "failed_cases")).to be(true)
  end

  it "honors project-only apps, custom destination, artifacts, dependencies, and timeout" do
    step = described_class.grade_steps(
      config: {
        "name" => "smoke",
        "display_name" => "Simulator smoke",
        "project" => "MobileApp.xcodeproj",
        "scheme" => "SmokeTests",
        "destination" => "platform=iOS Simulator,name=iPhone 15,OS=17.5",
        "derived_data_path" => ".syrus/DerivedData/smoke",
        "result_bundle_path" => "build/syrus/smoke.xcresult",
        "args" => [ "-only-testing:SmokeTests/LoginTests" ],
        "deps" => [ "//apps/ios:prepare" ],
        "phases" => [ "landing" ],
        "timeout_minutes" => 30,
        "required" => false
      },
      default_failures: "strict"
    ).first

    expect(step.name).to eq("smoke")
    expect(step.display_name).to eq("Simulator smoke")
    expect(step.run).to include("-project MobileApp.xcodeproj")
    expect(step.run).to include("-destination platform\\=iOS\\ Simulator,name\\=iPhone\\ 15,OS\\=17.5")
    expect(step.run).to include("-only-testing:SmokeTests/LoginTests")
    expect(step.deps).to eq([ "//apps/ios:prepare" ])
    expect(step.phases).to eq([ "landing" ])
    expect(step.timeout_minutes).to eq(30)
    expect(step.required).to be(false)
  end

  it "uses root-relative artifact paths for nested iOS projects" do
    step = described_class.grade_steps(
      config: {
        "_syrus_project_path" => "apps/ios",
        "workspace" => "MobileApp.xcworkspace",
        "scheme" => "MobileApp"
      },
      default_failures: "strict"
    ).first

    expect(step.run).to include("-workspace apps/ios/MobileApp.xcworkspace")
    expect(step.run).to include("-derivedDataPath apps/ios/.syrus/DerivedData/apps-ios-ios-tests")
    expect(step.run).to include("-resultBundlePath apps/ios/build/syrus/apps-ios-ios-tests.xcresult")
    expect(step.metadata["artifact_outputs"]).to include(
      { "artifact" => "apps/ios/build/syrus/apps-ios-ios-tests.xcresult", "format" => "xcresult" }
    )
  end

  it "rejects ambiguous Xcode containers" do
    expect {
      described_class.grade_steps(
        config: { "workspace" => "MobileApp.xcworkspace", "project" => "MobileApp.xcodeproj", "scheme" => "MobileApp" },
        default_failures: "strict"
      )
    }.to raise_error(ArgumentError, "set exactly one of workspace or project")
  end

  it "rejects invalid typed-grader capabilities" do
    expect {
      described_class.grade_steps(
        config: { "workspace" => "MobileApp.xcworkspace", "scheme" => "MobileApp", "capabilities" => { "os" => "windows" } },
        default_failures: "strict"
      )
    }.to raise_error(ArgumentError, /capabilities.os: values must be one of linux, macos/)
  end
end
