require "rails_helper"

RSpec.describe Ios::SwiftpmGraderType do
  it "registers the swiftpm type name" do
    expect(described_class.type_name).to eq("swiftpm")
  end

  it "expands to an isolated Swift Package Manager test grader" do
    step = described_class.grade_steps(config: {}, default_failures: "strict").first

    expect(step).to have_attributes(
      name: "swiftpm-tests",
      display_name: "Swift Package Manager tests",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 45,
      junit_output: nil
    )
    expect(step.run).to include("swift test --build-path .syrus/DerivedData/swiftpm-tests")
    expect(step.capabilities.to_h).to eq(
      "os" => [ "macos" ],
      "arch" => [ "arm64" ],
      "toolchain" => [ "xcode" ],
      "runtime" => [ "ios_simulator" ]
    )
    expect(step.metadata["artifact_outputs"]).to eq([
      { "artifact" => ".syrus/DerivedData/swiftpm-tests", "format" => "swiftpm_build" }
    ])
    expect(step.metadata.dig("filter_capabilities", "failed_cases")).to be(false)
  end

  it "honors package path, build action, configuration, arguments, JUnit output, and Linux overrides" do
    step = described_class.grade_steps(
      config: {
        "name" => "shared-build",
        "action" => "build",
        "package_path" => "Packages/Shared",
        "build_path" => ".syrus/DerivedData/shared",
        "configuration" => "release",
        "args" => [ "--build-tests" ],
        "junit_output" => "build/syrus/junit/shared.xml",
        "capabilities" => { "os" => "linux", "arch" => "x86_64", "toolchain" => "swift" }
      },
      default_failures: "strict"
    ).first

    expect(step.run).to include("swift build --package-path Packages/Shared --build-path .syrus/DerivedData/shared -c release --build-tests")
    expect(step.junit_output).to eq("build/syrus/junit/shared.xml")
    expect(step.capabilities.to_h).to eq(
      "os" => [ "linux" ],
      "arch" => [ "x86_64" ],
      "toolchain" => [ "swift" ]
    )
    expect(step.metadata["result_outputs"]).to eq([
      { "artifact" => "build/syrus/junit/shared.xml", "format" => "junit" }
    ])
  end

  it "uses nested project paths as Swift package paths and root-relative artifact paths" do
    step = described_class.grade_steps(
      config: { "_syrus_project_path" => "apps/ios" },
      default_failures: "strict"
    ).first

    expect(step.run).to include("swift test --package-path apps/ios --build-path apps/ios/.syrus/DerivedData/apps-ios-swiftpm-tests")
  end

  it "makes configured SwiftPM package paths root-relative for nested projects" do
    step = described_class.grade_steps(
      config: { "_syrus_project_path" => "apps/ios", "package_path" => "Packages/Shared" },
      default_failures: "strict"
    ).first

    expect(step.run).to include("swift test --package-path apps/ios/Packages/Shared --build-path apps/ios/.syrus/DerivedData/apps-ios-swiftpm-tests")
  end

  it "rejects unsupported actions" do
    expect {
      described_class.grade_steps(config: { "action" => "archive" }, default_failures: "strict")
    }.to raise_error(ArgumentError, "action must be build or test")
  end
end
