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

    expect(command).to eq("export RAILS_ENV=test COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-_syrus_flaky_8c116b9c}; if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi && bundle exec rspec spec/models/widget_spec.rb")
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

  it "uses the grader's RSpec worker when the grader command runs through one" do
    command = described_class.command_for(
      grader_name: "rspec-focused",
      grader_command: "bundle exec parallel_rspec --exec-args bin/rspec-worker $(cat .syrus/rspec-focused-files)",
      failed_cases: [
        { "suite_name" => "spec/models/widget_spec.rb", "name" => "Widget fails", "file_path" => "spec/models/widget_spec.rb" }
      ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to eq("export RAILS_ENV=test COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-_syrus_flaky_f58c1da8}; if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi && bin/rspec-worker spec/models/widget_spec.rb")
  end

  it "declines non-rspec graders" do
    command = described_class.command_for(
      grader_name: "react-tests",
      grader_command: "npx vitest run",
      failed_cases: [ { "file_path" => "app/frontend/App.test.tsx", "name" => "fails" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to be_nil
  end
end
