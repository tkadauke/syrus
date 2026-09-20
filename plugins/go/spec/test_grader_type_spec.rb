require "rails_helper"

RSpec.describe Go::TestGraderType do
  it "registers the go-test type name" do
    expect(described_class.type_name).to eq("go-test")
  end

  it "expands to a root Go test grader" do
    step = described_class.grade_steps(config: {}, default_failures: "strict").first

    expect(step).to have_attributes(
      name: "go-tests",
      run: "mise exec go@1.26.5 -- go test ./...",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 5,
      when_files_changed: [ "**/*.go", "go.mod", "go.sum", "Makefile" ]
    )
    expect(step.metadata).to include(
      "grader_type" => "go-test",
      "grader_framework" => "go",
      "grader_mode" => "test"
    )
  end

  it "runs nested module paths from the repository root" do
    step = described_class.grade_steps(
      config: { "_syrus_project_path" => "plugins/example", "path" => "cli" },
      default_failures: "strict"
    ).first

    expect(step.run).to eq("mise exec go@1.26.5 -- sh -c 'cd plugins/example/cli && go test ./...'")
    expect(step.when_files_changed).to eq([ "cli/**/*.go", "cli/go.mod", "cli/go.sum", "cli/Makefile" ])
  end

  it "passes dependencies and timeout through" do
    step = described_class.grade_steps(
      config: { "deps" => [ "//cli:grade/go-tests" ], "timeout_minutes" => 8, "required" => false },
      default_failures: "strict"
    ).first

    expect(step.deps).to eq([ "//cli:grade/go-tests" ])
    expect(step.timeout_minutes).to eq(8)
    expect(step.required).to be(false)
  end
end
