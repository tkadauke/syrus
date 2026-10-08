require "rails_helper"

RSpec.describe Java::MavenGraderType do
  it "registers the maven type name" do
    expect(described_class.type_name).to eq("maven")
  end

  it "expands to a wrapper-aware Maven test grader with standard report paths" do
    step = described_class.grade_steps(config: {}, default_failures: "strict").first

    expect(step).to have_attributes(
      name: "maven-test",
      display_name: "Maven tests",
      run: include("./mvnw -B test"),
      junit_output: ".syrus/grade-output/maven-test-junit.xml",
      when_files_changed: include("**/*.java", "pom.xml", ".mvn/**/*", "mvnw")
    )
    expect(step.run).to include("mvn -B test")
    expect(step.run).to include("target/surefire-reports")
    expect(step.run).to include("target/failsafe-reports")
    expect(step.metadata).to include(
      "grader_type" => "maven",
      "grader_framework" => "maven",
      "grader_mode" => "test"
    )
    expect(step.metadata["result_outputs"]).to eq([
      { "artifact" => ".syrus/grade-output/maven-test-junit.xml", "format" => "junit" }
    ])
  end

  it "honors configured goals and report paths" do
    step = described_class.grade_steps(
      config: {
        "name" => "maven-verify",
        "goals" => [ "clean", "verify" ],
        "report_paths" => [ "service-a/target/surefire-reports" ],
        "junit_output" => ".syrus/java/maven.xml"
      },
      default_failures: "strict"
    ).first

    expect(step.run).to include("./mvnw -B clean verify")
    expect(step.run).to include("service-a/target/surefire-reports")
    expect(step.junit_output).to eq(".syrus/java/maven.xml")
    expect(step.metadata["result_outputs"]).to eq([
      { "artifact" => ".syrus/java/maven.xml", "format" => "junit" }
    ])
  end

  it "prefixes configured report paths for nested projects" do
    step = described_class.grade_steps(
      config: { "_syrus_project_path" => "libraries/core", "goal" => "verify", "report_paths" => [ "target/failsafe-reports" ] },
      default_failures: "strict"
    ).first

    expect(step.run).to include("(cd libraries/core && if [ -x ./mvnw ]; then ./mvnw -B verify")
    expect(step.run).to include("libraries/core/target/failsafe-reports")
    expect(step.junit_output).to eq(".syrus/grade-output/libraries-core-maven-test-junit.xml")
  end
end
