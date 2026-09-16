require "rails_helper"
require "tmpdir"

RSpec.describe Steps::GraderCollect, "new-test flakiness gate" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:loop_id) { SecureRandom.uuid }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 101,
      iteration: 1,
      loop_id: loop_id
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }
  let!(:grader_step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 100,
      iteration: 1,
      loop_id: loop_id,
      state: "succeeded",
      # Deliberately no base_retry -- most graders, including this repo's own
      # rspec grader, never opt into BaseRevisionRetry's `base_retry: {
      # strategy: plugin }`. The gate must still work without it (see the
      # "without any base_retry configured" example below).
      details: { "name" => "rspec", "required" => true }
    )
  end

  around do |example|
    Dir.mktmpdir("syrus-grader-collect-flaky") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  def stub_git_diff(entries)
    diff_output = entries.map { |status, path| "#{status}\t#{path}" }.join("\n")
    git = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).with("diff", "--name-status", anything, chdir: @ws_path.to_s).and_return(diff_output)
    allow(git).to receive(:run).with("rev-parse", anything, chdir: @ws_path.to_s).and_return("abc123\n")
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, path: @ws_path, base_ref: "origin/main")
    allow(handler).to receive(:workspace).and_return(fake_ws)
    job.repository.update!(new_test_flakiness_gate_enabled: true)
  end

  it "skips the gate entirely when the diff touches no spec files" do
    stub_git_diff([ [ "M", "app/models/widget.rb" ] ])

    expect(TouchedTestRepeatGate).not_to receive(:call)

    expect { handler.call }.not_to raise_error

    expect(workflow.reload.artifact("new_test_flakiness_gate")).to be_nil
  end

  it "does not run the gate at all when the repository has not opted in" do
    job.repository.update!(new_test_flakiness_gate_enabled: false)
    stub_git_diff([ [ "A", "spec/new_spec.rb" ] ])

    expect(TouchedTestRepeatGate).not_to receive(:call)

    expect { handler.call }.not_to raise_error
  end

  it "fails with a distinct signal when a touched test's repeat runs disagree" do
    stub_git_diff([ [ "A", "spec/flaky_spec.rb" ] ])
    inconsistent_result = TouchedTestRepeatGate::Result.new(
      ran: true, consistent: false, reason: "repeat_run_inconsistent",
      grader_name: "rspec", command: "bundle exec rspec spec/flaky_spec.rb",
      files: [ "spec/flaky_spec.rb" ], repeats: 5, pass_count: 3, fail_count: 2
    )
    allow(TouchedTestRepeatGate).to receive(:call).and_return(inconsistent_result)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed) do |error|
      expect(error.problem.code).to eq("grader_failure")
      expect(error.evidence[:new_test_flakiness]).to be(true)
      expect(error.message).to include("rspec (2/5 failed)")
    end

    entries = workflow.reload.artifact("new_test_flakiness_gate")
    expect(entries.first).to include("name" => "new-test-flakiness-gate: rspec", "status" => "failed", "fail_count" => 2, "pass_count" => 3)

    iteration_entries = workflow.artifact("iterations").last
    expect(iteration_entries.map { |entry| entry["name"] }).to include("new-test-flakiness-gate: rspec")
  end

  it "detects real day-one flakiness end to end, through the real TouchedTestRepeatGate, without any base_retry configured" do
    stub_git_diff([ [ "A", "spec/flaky_spec.rb" ] ])
    counter = @ws_path.join("counter")
    counter.write("0")
    # Alternates fail/pass across repeats -- a real subprocess run, not a
    # stubbed Result, so this exercises TouchedTestRepeatGate's actual
    # command-building path (grader_step above has no base_retry at all).
    provider = double("focused_test_command_provider")
    allow(provider).to receive(:command_for)
      .and_return("n=$(cat #{counter}); n=$((n+1)); echo $n > #{counter}; test $((n % 2)) -eq 0")
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:focused_test_command).and_return([ provider ])
    job.repository.update!(new_test_flakiness_gate_repeats: 4)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed) do |error|
      expect(error.problem.code).to eq("grader_failure")
      expect(error.evidence[:new_test_flakiness]).to be(true)
    end

    entries = workflow.reload.artifact("new_test_flakiness_gate")
    expect(entries.first).to include("name" => "new-test-flakiness-gate: rspec", "repeats" => 4)
    expect(entries.first["pass_count"] + entries.first["fail_count"]).to eq(4)
  end

  it "does not fail when the touched test's repeat runs all agree" do
    stub_git_diff([ [ "A", "spec/stable_spec.rb" ] ])
    consistent_result = TouchedTestRepeatGate::Result.new(
      ran: true, consistent: true, reason: "repeat_run_consistent",
      grader_name: "rspec", command: "bundle exec rspec spec/stable_spec.rb",
      files: [ "spec/stable_spec.rb" ], repeats: 5, pass_count: 5, fail_count: 0
    )
    allow(TouchedTestRepeatGate).to receive(:call).and_return(consistent_result)

    expect { handler.call }.not_to raise_error

    expect(workflow.reload.artifact("new_test_flakiness_gate")).to be_nil
  end
end
