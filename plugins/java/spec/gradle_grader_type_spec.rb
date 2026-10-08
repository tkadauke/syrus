require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe Java::GradleGraderType do
  it "registers the gradle type name" do
    expect(described_class.type_name).to eq("gradle")
  end

  it "expands to a wrapper-aware Gradle test grader with Java/JVM scope and JUnit metadata" do
    step = described_class.grade_steps(config: {}, default_failures: "strict").first

    expect(step).to have_attributes(
      name: "gradle-test",
      display_name: "Gradle tests",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 20,
      junit_output: ".syrus/grade-output/gradle-test-junit.xml",
      when_files_changed: include("**/*.java", "build.gradle.kts", "gradlew", "pom.xml", ".mvn/**/*")
    )
    expect(step.run).to include("./gradlew --no-daemon test")
    expect(step.run).to include("gradle --no-daemon test")
    expect(step.run).to include("build/test-results/test")
    expect(step.run).to include("*/build/test-results/test")
    expect(step.metadata).to include(
      "grader_type" => "gradle",
      "grader_framework" => "gradle",
      "grader_mode" => "test"
    )
    expect(step.metadata["result_outputs"]).to eq([
      { "artifact" => ".syrus/grade-output/gradle-test-junit.xml", "format" => "junit" }
    ])
    expect(step.metadata.dig("filter_capabilities", "failed_cases")).to be(true)
  end

  it "honors configured tasks, display name, dependencies, timeout, and required flag" do
    step = described_class.grade_steps(
      config: {
        "name" => "jvm-unit",
        "display_name" => "JVM unit tests",
        "tasks" => [ "clean", "test" ],
        "deps" => [ "//:prepare" ],
        "timeout_minutes" => 30,
        "required" => false
      },
      default_failures: "strict"
    ).first

    expect(step.name).to eq("jvm-unit")
    expect(step.display_name).to eq("JVM unit tests")
    expect(step.run).to include("./gradlew --no-daemon clean test")
    expect(step.deps).to eq([ "//:prepare" ])
    expect(step.timeout_minutes).to eq(30)
    expect(step.required).to be(false)
  end

  it "uses nested project wrappers while leaving the aggregate JUnit output at the repository root" do
    step = described_class.grade_steps(
      config: { "_syrus_project_path" => "services/api", "task" => "check" },
      default_failures: "strict"
    ).first

    expect(step.run).to include("(cd services/api && if [ -x ./gradlew ]; then ./gradlew --no-daemon check")
    expect(step.run).to include("services/api/build/test-results/test")
    expect(step.junit_output).to eq(".syrus/grade-output/services-api-gradle-test-junit.xml")
  end

  it "can disable JUnit ingestion for repositories that do not emit XML reports" do
    step = described_class.grade_steps(config: { "junit_output" => false }, default_failures: "strict").first

    expect(step.junit_output).to be_nil
    expect(step.metadata["result_outputs"]).to eq([])
    expect(step.metadata.dig("filter_capabilities", "failed_cases")).to be(false)
  end

  it "aggregates standard Gradle JUnit XML files even when the test command fails" do
    Dir.mktmpdir("syrus-java-gradle-grader") do |dir|
      FileUtils.mkdir_p(File.join(dir, "build/test-results/test"))
      File.write(File.join(dir, "build/test-results/test/TEST-example.xml"), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="ExampleTest" tests="1">
          <testcase classname="ExampleTest" name="passes"/>
        </testsuite>
      XML
      File.write(File.join(dir, "gradlew"), "#!/bin/sh\nexit 3\n")
      File.chmod(0o755, File.join(dir, "gradlew"))

      command = described_class.grade_steps(config: {}, default_failures: "strict").first.run
      _stdout, stderr, status = Open3.capture3("bash", "-c", command, chdir: dir)

      expect(status.exitstatus).to eq(3), stderr
      output = File.read(File.join(dir, ".syrus/grade-output/gradle-test-junit.xml"))
      expect(output).to include("<testsuites>")
      expect(output).to include("<testsuite name=\"ExampleTest\"")
      expect(output).not_to include("<?xml")
    end
  end
end
