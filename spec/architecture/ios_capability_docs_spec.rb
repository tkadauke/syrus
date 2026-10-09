require "rails_helper"

RSpec.describe "iOS capability documentation" do
  OPERATOR_DOC = Rails.root.join("config/syrus_docs/syrus_yml.md")
  RUNBOOK_DOC = Rails.root.join("config/syrus_docs/ios_compute_runbook.md")
  PUBLIC_DOCS = [
    Rails.root.join("website/src/content/docs/configuration.md"),
    Rails.root.join("website/src/content/docs/monorepo-adoption.md"),
    Rails.root.join("website/src/content/docs/ios-compute-runbook.md")
  ].freeze

  it "documents the supported scheduler contract and practical Xcode inputs" do
    body = OPERATOR_DOC.read

    expect(body).to include("### iOS projects and Xcode targets")
    expect(body).to include("os: macos")
    expect(body).to include("arch: arm64")
    expect(body).to include("toolchain: xcode")
    expect(body).to include("runtime: ios_simulator")
    expect(body).to include("-workspace")
    expect(body).to include("-project")
    expect(body).to include("-scheme")
    expect(body).to include("-destination")
    expect(body).to include("-derivedDataPath")
    expect(body).to include("-resultBundlePath")
    expect(body).to include("CODE_SIGNING_ALLOWED=NO")
    expect(body).to include("type: xcodebuild")
    expect(body).to include("type: swiftpm")
    expect(body).to include("JUnit")
    expect(body).to include("\"planned_execution\"")
    expect(body).to include("Xcode license")
    expect(body).to include("simulator runtime")
    expect(body).to include("Keychain")
  end

  it "documents the iOS compute readiness runbook" do
    body = RUNBOOK_DOC.read

    expect(body).to include("iOS compilation")
    expect(body).to include("Coding Mode iOS/editor integration is not part of this release")
    expect(body).to include("planned primary execution")
    expect(body).to include("\"capabilities\"")
    expect(body).to include("implementation_capability_escalation")
    expect(body).to include("runs-macos-arm64")
    expect(body).to include("no_capable_worker")
    expect(body).to include("start_blocked_details")
    expect(body).to include("read_worker_health")
    expect(body).to include("read_queue")
    expect(body).to include("bin/macos-worker-check")
    expect(body).to include("launchd")
    expect(body).to include("Linux")
    expect(body).to include("Xcode")
    expect(body).to include("iOS simulator")
  end

  it "keeps public docs aligned with the iOS capability contract" do
    PUBLIC_DOCS.each do |path|
      body = path.read

      expect(body).to include("os: macos"), "#{path} should show macOS placement"
      expect(body).to include("xcodebuild"), "#{path} should mention Xcode execution"
      expect(body).to include("type: xcodebuild"), "#{path} should mention the typed Xcode grader"
      expect(body).to include("DerivedData"), "#{path} should mention build isolation"
      expect(body).to match(/result bundle|resultBundlePath/), "#{path} should mention result bundle output"
      expect(body).to include("JUnit"), "#{path} should mention test output paths"
      expect(body).to include("arch"), "#{path} should include architecture placement"
      expect(body).to include("toolchain"), "#{path} should include toolchain placement"
      expect(body).to include("runtime"), "#{path} should include runtime placement"
    end
  end
end
