require "rails_helper"
require "open3"
require "tmpdir"

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
    expect(step.run).to include("COMPILATION_CACHE_ENABLE_CACHING\\=YES")
    expect(step.run).to include("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS\\=YES")
    expect(step.run).to include('SYRUS_XCODE_COMPILATION_CACHE_ROOT:-${SYRUS_DATA_ROOT:-/var/lib/syrus}/cache/xcode-compilation')
    expect(step.capabilities.to_h).to eq(
      "os" => [ "macos" ],
      "arch" => [ "arm64" ],
      "toolchain" => [ "xcode" ],
      "runtime" => [ "ios_simulator" ]
    )
    expect(step.metadata["artifact_outputs"]).to include(
      { "artifact" => "build/syrus/ios-tests.xcresult", "format" => "xcresult" },
      { "artifact" => ".syrus/DerivedData/ios-tests", "format" => "derived_data" },
      { "artifact" => "build/syrus/ios-tests-compilation-cache.log", "format" => "xcode_compilation_cache_log" }
    )
    expect(step.metadata["compilation_cache"]).to eq(
      "requested" => true,
      "provider" => "xcode_native_cas",
      "diagnostic_artifact" => "build/syrus/ios-tests-compilation-cache.log",
      "retention_days" => 21
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

  it "allows native compilation caching to be disabled explicitly" do
    step = described_class.grade_steps(
      config: { "project" => "MobileApp.xcodeproj", "scheme" => "MobileApp", "compilation_cache" => false },
      default_failures: "strict"
    ).first

    expect(step.metadata.dig("compilation_cache", "requested")).to be(false)
    expect(step.run).to include("disabled by grader configuration; running uncached")
  end

  it "rejects invalid cache configuration" do
    expect {
      described_class.grade_steps(
        config: { "project" => "MobileApp.xcodeproj", "scheme" => "MobileApp", "compilation_cache" => "yes" },
        default_failures: "strict"
      )
    }.to raise_error(ArgumentError, "compilation_cache must be true or false")

    expect {
      described_class.grade_steps(
        config: { "project" => "MobileApp.xcodeproj", "scheme" => "MobileApp", "compilation_cache_retention_days" => 91 },
        default_failures: "strict"
      )
    }.to raise_error(ArgumentError, "compilation_cache_retention_days must be an integer from 1 to 90")
  end

  it "feature-detects unsupported Xcode and runs uncached" do
    with_fake_xcode(version: "Xcode 16.4\nBuild version 16F6\n", swift_cache: false) do |dir, env, calls|
      output, status = run_generated_grader(dir, env)

      expect(status).to be_success
      expect(output).to include("unsupported or probe unhealthy")
      expect(File.read(calls)).not_to include("COMPILATION_CACHE_ENABLE_CACHING=YES")
    end
  end

  it "uses a persistent toolchain generation path and preserves active cache generations during cleanup" do
    with_fake_xcode do |dir, env, calls|
      cache_root = Pathname(env.fetch("SYRUS_XCODE_COMPILATION_CACHE_ROOT"))
      stale = cache_root.join("old-toolchain", "old-generation")
      active = cache_root.join("active-toolchain", "active-generation")
      FileUtils.mkdir_p([ stale, active ])
      FileUtils.touch(active.join(".syrus-active-elsewhere"))
      old = 30.days.ago.to_time
      File.utime(old, old, stale)
      File.utime(old, old, active)

      output, status = run_generated_grader(dir, env)

      expect(status).to be_success
      cache_path = output.match(%r{enabled; path=(#{Regexp.escape(cache_root.to_s)}/[0-9a-f]{16}/\d{4}-\d{2})}).captures.fetch(0)
      invocation = File.read(calls)
      expect(invocation).to include("COMPILATION_CACHE_ENABLE_CACHING=YES")
      expect(invocation).to include("COMPILATION_CACHE_CAS_PATH=#{cache_path}")
      expect(stale).not_to exist
      expect(active).to exist
    end
  end

  it "fails open by retrying without caching after a native CAS error" do
    with_fake_xcode(fail_cached: true) do |dir, env, calls|
      output, status = run_generated_grader(dir, env)

      expect(status).to be_success
      expect(output).to include("cache became unhealthy; retrying once")
      invocations = File.readlines(calls)
      expect(invocations.count { |line| line.include?("COMPILATION_CACHE_ENABLE_CACHING=YES") }).to eq(1)
      expect(invocations.last).not_to include("COMPILATION_CACHE_ENABLE_CACHING=YES")
    end
  end

  it "refuses a broad cache root rather than risking broad cleanup" do
    with_fake_xcode do |dir, env, calls|
      env["SYRUS_XCODE_COMPILATION_CACHE_ROOT"] = "/tmp"
      output, status = run_generated_grader(dir, env)

      expect(status).to be_success
      expect(output).to include("unsafe cache root /tmp; running uncached")
      expect(File.read(calls)).not_to include("COMPILATION_CACHE_ENABLE_CACHING=YES")
    end
  end

  def run_generated_grader(dir, env)
    step = described_class.grade_steps(
      config: { "project" => "MobileApp.xcodeproj", "scheme" => "MobileApp" },
      default_failures: "strict"
    ).first
    stdout, stderr, status = Open3.capture3(env, "bash", "-c", step.run, chdir: dir)
    [ stdout + stderr, status ]
  end

  def with_fake_xcode(version: "Xcode 26.1\nBuild version 17B55\n", swift_cache: true, fail_cached: false)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      calls = File.join(dir, "xcodebuild.calls")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "xcodebuild"), <<~BASH)
        #!/usr/bin/env bash
        if [ "$1" = "-version" ]; then printf '#{version.gsub("'", %q('\\''))}'; exit 0; fi
        printf '%s\n' "$*" >> "$FAKE_XCODE_CALLS"
        if [ "$FAIL_CACHED" = true ] && [[ "$*" == *COMPILATION_CACHE_ENABLE_CACHING=YES* ]]; then
          echo 'CAS error: cache unavailable'
          exit 1
        fi
        echo 'Build succeeded'
      BASH
      File.write(File.join(bin, "xcrun"), <<~BASH)
        #!/usr/bin/env bash
        if [ "$1" = swiftc ] && [ "$2" = -help-hidden ]; then
          #{swift_cache ? "echo '  -cache-compile-job'" : "echo 'Swift help'"}
          exit 0
        fi
        exit 1
      BASH
      FileUtils.chmod(0o755, [ File.join(bin, "xcodebuild"), File.join(bin, "xcrun") ])
      env = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "FAKE_XCODE_CALLS" => calls,
        "FAIL_CACHED" => fail_cached.to_s,
        "SYRUS_XCODE_COMPILATION_CACHE_ROOT" => File.join(dir, "persistent-cache")
      }
      yield dir, env, calls
    end
  end
end
