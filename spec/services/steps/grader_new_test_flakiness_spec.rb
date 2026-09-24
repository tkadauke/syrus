require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Grader, "new-test flakiness gate" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 100,
      details: {
        "name" => "plugins-example-rspec",
        "command" => 'RAILS_ENV=${RAILS_ENV:-test} COVERAGE=false bundle exec rspec plugins/example/spec',
        "required" => true,
        "grader_framework" => "rspec",
        "when_files_changed" => [ "plugins/example/spec/**/*.rb" ],
        "log_path" => ".syrus/grade-output/rspec.log"
      }
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: 1) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-grader-flaky") do |dir|
      @ws_path = Pathname.new(dir)
      FileUtils.mkdir_p(@ws_path.join(".syrus/grade-output"))
      @ws_path.join(".syrus/grade-output/rspec.log").write("")
      example.run
    end
  end

  before do
    job.repository.update!(new_test_flakiness_gate_enabled: true, new_test_flakiness_gate_repeats: 4)
    allow(handler).to receive(:workspace).and_return(instance_double(WorkflowWorkspace, path: @ws_path))
    allow(handler).to receive(:base_revision_sha).and_return("base123")
    allow(handler).to receive(:env).and_return({})
    allow(TouchedTestFiles).to receive(:call).and_return([
      "spec/core_spec.rb",
      "plugins/example/spec/widget_spec.rb",
      "plugins/other/spec/other_spec.rb"
    ])
  end

  it "runs repeat checks inside the owning typed grader with project-scoped files" do
    result = TouchedTestRepeatGate::Result.new(
      ran: true, consistent: true, reason: "repeat_run_consistent",
      grader_name: "plugins-example-rspec",
      command: "bundle exec rspec plugins/example/spec/widget_spec.rb",
      normal_command: "RAILS_ENV=${RAILS_ENV:-test} COVERAGE=false bundle exec rspec plugins/example/spec",
      files: [ "plugins/example/spec/widget_spec.rb" ],
      repeats: 4,
      pass_count: 4,
      fail_count: 0,
      runs: [],
      env: { "RAILS_ENV" => "test", "COVERAGE" => "false" }
    )
    expect(TouchedTestRepeatGate).to receive(:call).with(hash_including(
      grader_step: step,
      touched_files: [ "plugins/example/spec/widget_spec.rb" ],
      repeats: 4,
      workspace_path: @ws_path
    )).and_return(result)

    expect { handler.send(:check_new_test_flakiness!, name: "plugins-example-rspec", definition: step.details) }.not_to raise_error

    expect(step.reload.details.dig("new_test_flakiness_gate", "consistent")).to be(true)
    expect(step.details.dig("new_test_flakiness_gate", "env")).to include("RAILS_ENV" => "test", "COVERAGE" => "false")
  end

  it "fails the grader itself when repeat results are inconsistent" do
    result = TouchedTestRepeatGate::Result.new(
      ran: true, consistent: false, reason: "repeat_run_inconsistent",
      grader_name: "rspec",
      command: "bundle exec rspec plugins/example/spec/widget_spec.rb",
      normal_command: "bundle exec rspec",
      files: [ "plugins/example/spec/widget_spec.rb" ],
      repeats: 4,
      pass_count: 2,
      fail_count: 2,
      runs: [],
      env: {}
    )
    allow(TouchedTestRepeatGate).to receive(:call).and_return(result)

    expect { handler.send(:check_new_test_flakiness!, name: "plugins-example-rspec", definition: step.details) }
      .to raise_error(Steps::Base::StepFailed) { |error| expect(error.evidence[:new_test_flakiness]).to be(true) }

    expect(step.reload.details.dig("new_test_flakiness_gate", "consistent")).to be(false)
  end

  it "records all-repeat focused rerun failures without failing the already-passing grader" do
    result = TouchedTestRepeatGate::Result.new(
      ran: true, consistent: false, reason: "focused_command_failed_consistently",
      grader_name: "rspec",
      command: "bundle exec rspec plugins/example/spec/widget_spec.rb",
      normal_command: "bundle exec rspec",
      files: [ "plugins/example/spec/widget_spec.rb" ],
      repeats: 4,
      pass_count: 0,
      fail_count: 4,
      runs: [ { "exit_status" => 1, "output" => "boot failed", "passed" => false, "timed_out" => false } ],
      env: { "RAILS_ENV" => "test" }
    )
    allow(TouchedTestRepeatGate).to receive(:call).and_return(result)

    expect { handler.send(:check_new_test_flakiness!, name: "plugins-example-rspec", definition: step.details) }
      .not_to raise_error

    expect(step.reload.details.dig("new_test_flakiness_gate", "reason")).to eq("focused_command_failed_consistently")
    expect(step.details["output"]).to include("new-test repeat gate failed: focused_command_failed_consistently")
  end

  it "does not attach repeat checks to non-test graders" do
    definition = step.details.merge("grader_framework" => nil)

    expect(TouchedTestRepeatGate).not_to receive(:call)
    handler.send(:check_new_test_flakiness!, name: "lint", definition: definition)
  end

  it "does not attach repeat checks to already-focused test graders" do
    definition = step.details.merge("grader_mode" => "focused")

    expect(TouchedTestRepeatGate).not_to receive(:call)
    handler.send(:check_new_test_flakiness!, name: "plugins-example-rspec-focused", definition: definition)
  end

  it "does not attach repeat checks to focused graders missing mode metadata" do
    definition = step.details.merge("target_label" => "//plugins/example:grade/rspec-focused")

    expect(TouchedTestRepeatGate).not_to receive(:call)
    handler.send(:check_new_test_flakiness!, name: "plugins-example-rspec-focused", definition: definition)
  end
end
