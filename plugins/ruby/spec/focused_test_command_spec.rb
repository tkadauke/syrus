require "rails_helper"

RSpec.describe Ruby::FocusedTestCommand do
  it "synthesizes a focused RSpec command when the grader opts into plugin strategy" do
    command = described_class.command_for(
      grader_name: "rspec",
      grader_command: "bin/rspec",
      failed_cases: [
        { "suite_name" => "spec/models/widget_spec.rb", "name" => "Widget fails", "file_path" => "spec/models/widget_spec.rb" },
        { "suite_name" => "spec/models/widget_spec.rb", "name" => "Widget also fails", "file_path" => "spec/models/widget_spec.rb" }
      ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to eq("bundle exec rspec spec/models/widget_spec.rb")
  end

  it "declines when the grader did not opt into plugin strategy" do
    command = described_class.command_for(
      grader_name: "rspec",
      grader_command: "bin/rspec",
      failed_cases: [ { "file_path" => "spec/models/widget_spec.rb", "name" => "Widget fails" } ],
      base_retry: { "strategy" => "files_as_args" }
    )

    expect(command).to be_nil
  end

  it "declines non-rspec graders" do
    command = described_class.command_for(
      grader_name: "react-tests",
      grader_command: "bin/test-react",
      failed_cases: [ { "file_path" => "app/frontend/App.test.tsx", "name" => "fails" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to be_nil
  end
end
