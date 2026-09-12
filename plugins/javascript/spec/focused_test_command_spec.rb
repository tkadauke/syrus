require "rails_helper"

RSpec.describe JavaScript::FocusedTestCommand do
  it "focuses JavaScript graders to failed test files" do
    command = described_class.command_for(
      grader_name: "react-tests",
      grader_command: "bin/test-react",
      failed_cases: [
        { "file_path" => "app/frontend/routes/App.test.tsx", "name" => "renders dashboard" },
        { "suite_name" => "plugins/demo/app/frontend/demo.spec.ts", "name" => "renders" }
      ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to include("npm ci")
    expect(command).to include("npx vitest run --maxWorkers=1")
    expect(command).to include("--reporter=junit")
    expect(command).to include("app/frontend/routes/App.test.tsx plugins/demo/app/frontend/demo.spec.ts")
  end

  it "declines when the grader did not opt into plugin strategy" do
    command = described_class.command_for(
      grader_name: "react-tests",
      grader_command: "bin/test-react",
      failed_cases: [ { "file_path" => "app/frontend/routes/App.test.tsx", "name" => "renders dashboard" } ],
      base_retry: { "strategy" => "files_as_args" }
    )

    expect(command).to be_nil
  end

  it "declines non-JavaScript graders" do
    command = described_class.command_for(
      grader_name: "rspec",
      grader_command: "bin/rspec-fast",
      failed_cases: [ { "file_path" => "spec/models/job_spec.rb", "name" => "works" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to be_nil
  end
end
