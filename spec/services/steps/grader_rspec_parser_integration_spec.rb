require "rails_helper"
require "tmpdir"

# End-to-end coverage for SyrusRails::RspecParser against real RSpec output
# fixtures, running through the same path a live grader Step uses:
# Steps::Grader#ingest_test_output! -> TestRunIngester. Unlike
# spec/services/steps/grader_test_result_parser_spec.rb (which stubs the
# parser's return value with a double), this exercises the actual parser so a
# future TestResultParser contract regression fails a spec instead of being
# silently swallowed by Steps::Grader's rescue.
RSpec.describe "Steps::Grader real RSpec output ingestion" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:fixtures_path) { Rails.root.join("spec/fixtures/rspec") }

  before do
    unless Syrus::PluginRegistry.registered_names.include?("syrus-rails")
      Syrus::PluginRegistry.register(
        name:    "syrus-rails",
        version: SyrusRails::VERSION,
        provides: { test_result_parser: SyrusRails::RspecParser }
      )
    end
  end

  after { Syrus::PluginRegistry.reset! }

  around do |example|
    Dir.mktmpdir("syrus-grader-rspec-parser") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  def make_step(junit_output:)
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 99,
      details: {
        "name" => "rspec",
        "command" => "true",
        "required" => true,
        "timeout_minutes" => 1,
        "junit_output" => junit_output
      }
    )
  end

  def handler_for(step)
    run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration)
    handler = Steps::Grader.new(run)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    [ handler, run ]
  end

  def write_fixture(fixture_name, relative_output_path)
    output_path = @ws_path.join(relative_output_path)
    FileUtils.mkdir_p(output_path.dirname)
    FileUtils.cp(fixtures_path.join(fixture_name), output_path)
    output_path
  end

  it "ingests real RSpec progress-format output with one failure and one pending example" do
    write_fixture("progress_output.txt", "tmp/rspec_output.txt")
    step = make_step(junit_output: "tmp/rspec_output.txt")
    handler, run = handler_for(step)

    expect { handler.call }
      .to change(TestRun, :count).by(1)
      .and change(TestCase, :count).by(1)

    test_run = TestRun.find_by!(run: run, grader_name: "rspec")
    expect(test_run).to have_attributes(
      total_count: 8,
      passed_count: 6,
      failed_count: 1,
      skipped_count: 1,
      error_count: 0,
      duration_ms: 420
    )

    test_case = test_run.test_cases.sole
    expect(test_case).to have_attributes(
      name: "GreetingHelper#greet returns the user's name",
      suite_name: "spec/helpers/greeting_helper_spec.rb",
      file_path: "spec/helpers/greeting_helper_spec.rb",
      status: "failed"
    )
    expect(test_case.failure_message).to include("expected: \"Hello, Ada\"")
  end

  it "ingests real RSpec output with multiple failures in the same suite" do
    write_fixture("multiple_failures_output.txt", "tmp/rspec_output.txt")
    step = make_step(junit_output: "tmp/rspec_output.txt")
    handler, run = handler_for(step)

    expect { handler.call }
      .to change(TestRun, :count).by(1)
      .and change(TestCase, :count).by(2)

    test_run = TestRun.find_by!(run: run, grader_name: "rspec")
    expect(test_run).to have_attributes(total_count: 3, passed_count: 1, failed_count: 2)
    expect(test_run.test_cases.pluck(:suite_name)).to all(eq("spec/models/widget_spec.rb"))
    expect(test_run.test_cases.pluck(:name)).to contain_exactly(
      "Widget#price returns the base price",
      "Widget#price applies the discount"
    )
  end

  it "ingests real all-passing RSpec output without creating any TestCase rows" do
    write_fixture("passing_output.txt", "tmp/rspec_output.txt")
    step = make_step(junit_output: "tmp/rspec_output.txt")
    handler, run = handler_for(step)

    expect { handler.call }
      .to change(TestRun, :count).by(1)
      .and change(TestCase, :count).by(0)

    test_run = TestRun.find_by!(run: run, grader_name: "rspec")
    expect(test_run).to have_attributes(total_count: 6, passed_count: 6, failed_count: 0)
  end
end
