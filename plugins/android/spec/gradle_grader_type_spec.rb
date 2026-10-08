require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "Android Gradle grader types" do
  def matches_scope?(patterns, path)
    patterns.any? { |pattern| File.fnmatch(pattern, path, File::FNM_DOTMATCH) }
  end

  it "registers Android type names" do
    expect(Android::AssembleGraderType.type_name).to eq("android-assemble")
    expect(Android::UnitTestGraderType.type_name).to eq("android-unit-test")
    expect(Android::InstrumentedTestGraderType.type_name).to eq("android-instrumented-test")
    expect(Android::ManagedDeviceGraderType.type_name).to eq("android-managed-device")
  end

  it "expands assemble to a Linux Gradle task with Android package artifacts" do
    step = Android::AssembleGraderType.grade_steps(config: {}, default_failures: "strict").first

    expect(step).to have_attributes(
      name: "android-assemble",
      display_name: "Android assemble",
      run: include("./gradlew --no-daemon assembleDebug"),
      phases: %w[review landing ci],
      timeout_minutes: 30,
      junit_output: nil,
      capabilities: TargetGraph::ExecutionCapabilities.new(os: "linux")
    )
    expect(step.run).to include("gradle --no-daemon assembleDebug")
    expect(step.when_files_changed).to include("**/src/androidTest/**/*", "**/AndroidManifest.xml", "**/build.gradle.kts")
    expect(matches_scope?(step.when_files_changed, "app/src/main/res/values/strings.xml")).to be(true)
    expect(step.metadata).to include(
      "grader_type" => "android-assemble",
      "grader_framework" => "android-gradle",
      "grader_mode" => "assemble",
      "gradle_tasks" => [ "assembleDebug" ]
    )
    expect(step.metadata["artifact_paths"]).to include("*/build/outputs/apk", "*/build/outputs/bundle")
    expect(step.metadata["log_paths"]).to include("*/build/reports")
    expect(step.metadata["result_outputs"]).to eq([])
  end

  it "expands local unit tests with JUnit aggregation and report metadata" do
    step = Android::UnitTestGraderType.grade_steps(config: {}, default_failures: "strict").first

    expect(step).to have_attributes(
      name: "android-unit-test",
      display_name: "Android unit tests",
      run: include("./gradlew --no-daemon testDebugUnitTest"),
      timeout_minutes: 25,
      junit_output: ".syrus/grade-output/android-unit-test-junit.xml",
      capabilities: TargetGraph::ExecutionCapabilities.new(os: "linux")
    )
    expect(step.run).to include("build/test-results/testDebugUnitTest")
    expect(step.run).to include("*/build/test-results/test*UnitTest")
    expect(step.metadata["result_outputs"]).to eq([
      { "artifact" => ".syrus/grade-output/android-unit-test-junit.xml", "format" => "junit" }
    ])
    expect(step.metadata.dig("filter_capabilities", "failed_cases")).to be(true)
  end

  it "expands connected instrumented tests with Android test reports and artifacts" do
    step = Android::InstrumentedTestGraderType.grade_steps(config: {}, default_failures: "strict").first

    expect(step.name).to eq("android-instrumented-test")
    expect(step.run).to include("./gradlew --no-daemon connectedDebugAndroidTest")
    expect(step.timeout_minutes).to eq(45)
    expect(step.junit_output).to eq(".syrus/grade-output/android-instrumented-test-junit.xml")
    expect(step.metadata).to include(
      "grader_type" => "android-instrumented-test",
      "grader_mode" => "instrumented_test"
    )
    expect(step.metadata["artifact_paths"]).to include("*/build/outputs/androidTest-results/connected")
    expect(step.metadata["log_paths"]).to include("*/build/reports/androidTests/connected")
  end

  it "expands Gradle Managed Device tests from configured devices or explicit tasks" do
    from_devices = Android::ManagedDeviceGraderType.grade_steps(
      config: { "devices" => [ "pixel2api30" ], "variant" => "release" },
      default_failures: "strict"
    ).first
    from_tasks = Android::ManagedDeviceGraderType.grade_steps(
      config: { "tasks" => [ "pixelFoldDebugAndroidTest" ] },
      default_failures: "strict"
    ).first
    default = Android::ManagedDeviceGraderType.grade_steps(config: {}, default_failures: "strict").first

    expect(from_devices.run).to include("./gradlew --no-daemon pixel2api30ReleaseAndroidTest")
    expect(from_devices.metadata["managed_devices"]).to eq([ "pixel2api30" ])
    expect(from_tasks.run).to include("./gradlew --no-daemon pixelFoldDebugAndroidTest")
    expect(default.run).to include("./gradlew --no-daemon allDevicesCheck")
    expect(default.timeout_minutes).to eq(60)
    expect(default.metadata["artifact_paths"]).to include("*/build/outputs/managed_device_android_test_additional_output")
  end

  it "honors common configuration and nested project paths" do
    step = Android::UnitTestGraderType.grade_steps(
      config: {
        "_syrus_project_path" => "mobile/android",
        "name" => "mobile-unit",
        "display_name" => "Mobile unit tests",
        "tasks" => [ "testPaidDebugUnitTest" ],
        "report_paths" => [ "app/build/test-results/testPaidDebugUnitTest" ],
        "artifact_paths" => [ "app/build/outputs/apk" ],
        "deps" => [ "//mobile/android:prepare" ],
        "timeout_minutes" => 35,
        "required" => false
      },
      default_failures: "strict"
    ).first

    expect(step.name).to eq("mobile-unit")
    expect(step.display_name).to eq("Mobile unit tests")
    expect(step.run).to include("(cd mobile/android && if [ -x ./gradlew ]; then ./gradlew --no-daemon testPaidDebugUnitTest")
    expect(step.run).to include("mobile/android/app/build/test-results/testPaidDebugUnitTest")
    expect(step.junit_output).to eq(".syrus/grade-output/mobile-android-mobile-unit-junit.xml")
    expect(step.metadata["artifact_paths"]).to eq([ "mobile/android/app/build/outputs/apk" ])
    expect(step.deps).to eq([ "//mobile/android:prepare" ])
    expect(step.timeout_minutes).to eq(35)
    expect(step.required).to be(false)
  end

  it "expands Android types through .syrus.yml parsing with Linux capabilities" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_type).and_return([
      Android::AssembleGraderType,
      Android::UnitTestGraderType,
      Android::InstrumentedTestGraderType,
      Android::ManagedDeviceGraderType
    ])

    config = SyrusYml.new(<<~YAML).parse
      grade:
        - type: android-assemble
          tasks: [assembleDebug]
        - type: android-unit-test
          tasks: [testDebugUnitTest]
        - type: android-managed-device
          devices: [pixel2api30]
          variant: debug
    YAML

    expect(config.grade.steps.map(&:name)).to eq([
      "android-assemble",
      "android-unit-test",
      "android-managed-device"
    ])
    expect(config.grade.steps.map { |step| step.capabilities.to_h }).to all(eq("os" => [ "linux" ]))
    expect(config.grade.steps.last.run).to include("pixel2api30DebugAndroidTest")
  end

  it "keeps the documented Android app example parseable" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_type).and_return([
      Android::AssembleGraderType,
      Android::UnitTestGraderType,
      Android::ManagedDeviceGraderType
    ])

    config = SyrusYml.new(<<~YAML).parse
      grade:
        - type: android-assemble
          tasks: [assembleDebug]
        - type: android-unit-test
          tasks: [testDebugUnitTest]
        - type: android-managed-device
          tasks: [allDevicesCheck]
          phases: [landing, ci]
          timeout_minutes: 60
    YAML

    expect(config.grade.steps.last.phases).to eq(%w[landing ci])
    expect(config.grade.steps.last.timeout_minutes).to eq(60)
  end

  it "aggregates Android JUnit XML even when the Gradle command fails" do
    Dir.mktmpdir("syrus-android-gradle-grader") do |dir|
      FileUtils.mkdir_p(File.join(dir, "build/test-results/testDebugUnitTest"))
      File.write(File.join(dir, "build/test-results/testDebugUnitTest/TEST-example.xml"), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="ExampleAndroidUnitTest" tests="1">
          <testcase classname="ExampleAndroidUnitTest" name="passes"/>
        </testsuite>
      XML
      File.write(File.join(dir, "gradlew"), "#!/bin/sh\nexit 4\n")
      File.chmod(0o755, File.join(dir, "gradlew"))

      command = Android::UnitTestGraderType.grade_steps(config: {}, default_failures: "strict").first.run
      _stdout, stderr, status = Open3.capture3("bash", "-c", command, chdir: dir)

      expect(status.exitstatus).to eq(4), stderr
      output = File.read(File.join(dir, ".syrus/grade-output/android-unit-test-junit.xml"))
      expect(output).to include("<testsuites>")
      expect(output).to include("<testsuite name=\"ExampleAndroidUnitTest\"")
      expect(output).not_to include("<?xml")
    end
  end
end
