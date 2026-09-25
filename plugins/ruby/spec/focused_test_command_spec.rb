require "rails_helper"

RSpec.describe Ruby::FocusedTestCommand do
  let(:bundle_prefix) { 'BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle"' }

  it "provides a one-time Rails test database setup for focused RSpec repeats" do
    expect(described_class.prepare_command_for(grader_name: "rspec", grader_command: "bundle exec rspec")).to eq(
      "if [ -x bin/rails ] && [ -f config/database.yml ]; then RAILS_ENV=test bin/rails db:test:prepare; fi"
    )
  end

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

    expect(command).to eq("export RAILS_ENV=test RUN_CI_ONLY_SPECS=false COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-_syrus_flaky_8c116b9c}; (#{bundle_prefix} bundle check || #{bundle_prefix} bundle install --jobs \"${BUNDLE_INSTALL_JOBS:-1}\") && if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi && #{bundle_prefix} bundle exec rspec --tag ~ci_only spec/models/widget_spec.rb")
  end

  it "preserves ci_only inclusion for ci-only RSpec graders" do
    command = described_class.command_for(
      grader_name: "rspec-ci",
      grader_command: "RUN_CI_ONLY_SPECS=true bundle exec rspec",
      failed_cases: [ { "file_path" => "spec/migrations/widget_spec.rb", "name" => "Widget migrates" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to eq("export RAILS_ENV=test RUN_CI_ONLY_SPECS=true COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-_syrus_flaky_3de88a23}; (#{bundle_prefix} bundle check || #{bundle_prefix} bundle install --jobs \"${BUNDLE_INSTALL_JOBS:-1}\") && if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi && #{bundle_prefix} bundle exec rspec --tag ci_only spec/migrations/widget_spec.rb")
  end

  it "preserves explicit RSpec tag filters from the grader command" do
    command = described_class.command_for(
      grader_name: "rspec-focused",
      grader_command: "bundle exec rspec --tag ~ci_only",
      failed_cases: [ { "file_path" => "spec/models/widget_spec.rb" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to eq("export RAILS_ENV=test RUN_CI_ONLY_SPECS=false COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-_syrus_flaky_f58c1da8}; (#{bundle_prefix} bundle check || #{bundle_prefix} bundle install --jobs \"${BUNDLE_INSTALL_JOBS:-1}\") && if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi && #{bundle_prefix} bundle exec rspec --tag \\~ci_only spec/models/widget_spec.rb")
  end

  it "preserves RSpec tag filters passed through RSPEC_TAG_ARGS" do
    command = described_class.command_for(
      grader_name: "rspec-focused",
      grader_command: "RSPEC_TAG_ARGS=--tag\\ \\~ci_only bundle exec parallel_rspec --exec-args bin/rspec-worker",
      failed_cases: [ { "file_path" => "plugins/muse_agent/spec/services/muse_invocation_spec.rb" } ],
      base_retry: { "strategy" => "plugin" }
    )

    expect(command).to eq("export RAILS_ENV=test RUN_CI_ONLY_SPECS=false COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-_syrus_flaky_9ce22ed4}; (#{bundle_prefix} bundle check || #{bundle_prefix} bundle install --jobs \"${BUNDLE_INSTALL_JOBS:-1}\") && if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi && #{bundle_prefix} bin/rspec-worker --tag \\~ci_only plugins/muse_agent/spec/services/muse_invocation_spec.rb")
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

    expect(command).to eq("export RAILS_ENV=test RUN_CI_ONLY_SPECS=false COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-_syrus_flaky_f58c1da8}; (#{bundle_prefix} bundle check || #{bundle_prefix} bundle install --jobs \"${BUNDLE_INSTALL_JOBS:-1}\") && if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi && #{bundle_prefix} bin/rspec-worker --tag ~ci_only spec/models/widget_spec.rb")
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
