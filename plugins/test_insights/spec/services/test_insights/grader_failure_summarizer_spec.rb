require "rails_helper"
require "tmpdir"

# Core's Steps::GraderCollect asks :grader_failure_summarizer providers what
# failed; it never reaches into this plugin's models directly. These examples
# drive that through core's real step and this plugin's real provider and
# data, so they live here rather than in core's GraderCollect spec.
RSpec.describe TestInsights::GraderFailureSummarizer do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:loop_id) { SecureRandom.uuid }
  let(:step) do
    Step.create!(workflow: workflow, kind: "grader_collect", position: 101, iteration: 1, loop_id: loop_id)
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { Steps::GraderCollect.new(run) }
  let(:grader_step) { workflow.steps.find_by!(kind: "grader") }

  around do |example|
    Dir.mktmpdir("syrus-grader-failure-summary") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 100,
      iteration: 1,
      loop_id: loop_id,
      state: "failed",
      details: { "name" => "rspec", "required" => true, "command" => "bin/rspec", "exit_code" => 1 }
    )
    fake_ws = instance_double(WorkflowWorkspace, path: @ws_path, base_ref: "origin/main")
    git = instance_double(GitRunner, run: "abc123\n")
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(GitRunner).to receive(:new).and_return(git)
  end

  def seed_results!(grader_name: "rspec", total: 100, failures: [])
    grader_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed", iteration: 1)
    test_run = TestInsights::TestRun.create!(
      run: grader_run, repository: job.repository, grader_name: grader_name,
      total_count: total, passed_count: total - failures.size, failed_count: failures.size
    )
    failures.each do |failure|
      TestInsights::TestCase.create!(
        test_run: test_run,
        repository: job.repository,
        suite_name: failure[:file],
        file_path: failure[:file],
        name: failure[:name],
        status: failure.fetch(:status, "failed"),
        failure_message: failure[:message]
      )
    end
    grader_run
  end

  def summary_from_manifest
    workflow.reload.artifact(GraderLogArchive::MANIFEST_ARTIFACT_KEY).fetch("1").sole["failure_summary"]
  end

  # The point of the whole exercise: the records know about every failure, so
  # the summary lists every failure. The log excerpt this replaced showed two
  # of nine on a real landing iteration.
  it "lists every failing example, not a sample of them" do
    failures = Array.new(9) do |index|
      { file: "./spec/jobs/thing_#{index}_spec.rb", name: "example #{index}", message: "boom #{index}" }
    end
    seed_results!(total: 13_969, failures: failures)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    summary = summary_from_manifest
    expect(summary.first).to include("9 of 13969 examples failed")
    9.times { |index| expect(summary.join("\n")).to include("spec/jobs/thing_#{index}_spec.rb") }
  end

  it "groups failures by file with the first line of each assertion" do
    seed_results!(total: 50, failures: [
      { file: "./spec/jobs/browser_error_auto_report_job_spec.rb", name: "files one bug report when enabled",
        message: "#<InstanceDouble(BugReports::Router)> received unexpected message :mode\nand then a long diff\n" },
      { file: "./spec/jobs/browser_error_auto_report_job_spec.rb", name: "records a failed report claim",
        message: "#<InstanceDouble(BugReports::Router)> received unexpected message :mode\n" }
    ])

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    text = summary_from_manifest.join("\n")
    expect(text).to include("spec/jobs/browser_error_auto_report_job_spec.rb (2 failing)")
    expect(text).to include("files one bug report when enabled")
    expect(text).to include("received unexpected message :mode")
    expect(text).not_to include("and then a long diff")
  end

  it "strips the leading ./ so the paths are the ones the agent works with" do
    seed_results!(failures: [ { file: "./spec/a_spec.rb", name: "fails", message: "nope" } ])

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    expect(summary_from_manifest.join("\n")).to include("spec/a_spec.rb (1 failing)")
    expect(summary_from_manifest.join("\n")).not_to include("./spec/a_spec.rb")
  end

  it "counts errored examples as failures" do
    seed_results!(failures: [ { file: "./spec/a_spec.rb", name: "explodes", status: "error", message: "NoMethodError" } ])

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    expect(summary_from_manifest.join("\n")).to include("explodes")
  end

  it "caps a very long list and says what it left out" do
    failures = Array.new(40) { |index| { file: "./spec/file_#{index}_spec.rb", name: "e#{index}", message: "m#{index}" } }
    seed_results!(failures: failures)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    text = summary_from_manifest.join("\n")
    expect(text).to include("more file(s) with failures")
    expect(summary_from_manifest.size).to be <= GraderLogArchive::SUMMARY_LINE_LIMIT
  end

  it "keeps another grader's results out of this grader's summary" do
    seed_results!(grader_name: "react-tests", failures: [
      { file: "./app/frontend/thing.test.tsx", name: "renders", message: "snapshot mismatch" }
    ])
    seed_results!(grader_name: "rspec", failures: [
      { file: "./spec/a_spec.rb", name: "fails", message: "nope" }
    ])

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    text = summary_from_manifest.join("\n")
    expect(text).to include("spec/a_spec.rb")
    expect(text).not_to include("thing.test.tsx")
  end

  it "says nothing when the grader produced no test results at all" do
    grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed", iteration: 1)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    expect(workflow.reload.artifact(GraderLogArchive::MANIFEST_ARTIFACT_KEY).fetch("1").sole)
      .not_to have_key("failure_summary")
  end

  it "says nothing when the run's tests all passed" do
    seed_results!(total: 10, failures: [])

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    expect(workflow.reload.artifact(GraderLogArchive::MANIFEST_ARTIFACT_KEY).fetch("1").sole)
      .not_to have_key("failure_summary")
  end

  describe "the provider contract" do
    it "returns an empty summary rather than raising without a run" do
      expect(described_class.summarize_grader_failure(grader_step: grader_step, run: nil, grader_name: "rspec")).to eq([])
    end

    # Core drops a raising summarizer with a warning, but the contract says
    # not to raise in the first place.
    it "swallows an unexpected error instead of raising at core" do
      allow(TestInsights::TestRun).to receive(:for_run).and_raise(ActiveRecord::StatementInvalid, "boom")
      grader_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")

      expect(
        described_class.summarize_grader_failure(grader_step: grader_step, run: grader_run, grader_name: "rspec")
      ).to eq([])
    end
  end
end
