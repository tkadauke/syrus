require "rails_helper"
require "tmpdir"

RSpec.describe Steps::GraderCollect do
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

  around do |example|
    Dir.mktmpdir("syrus-grader-collect") do |dir|
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
      state: "succeeded",
      details: { "name" => "tests", "required" => true }
    )
    fake_ws = instance_double(WorkflowWorkspace, path: @ws_path, base_ref: "origin/main")
    git = instance_double(GitRunner, run: "abc123\n")
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(GitRunner).to receive(:new).and_return(git)
  end

  it "records successful grader conclusions for reuse" do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "grade-fingerprint")

    expect { handler.call }.to change(GraderConclusion, :count).by(2)

    per_grader = GraderConclusion.where(workflow: workflow, grader_name: "tests").sole
    expect(per_grader).to have_attributes(
      repository: job.repository,
      job: job,
      commit_sha: "abc123",
      grader_fingerprint: "grade-fingerprint",
      required: true,
      status: "passed"
    )

    aggregate = GraderConclusion.aggregate.where(workflow: workflow).sole
    expect(aggregate).to have_attributes(
      repository: job.repository,
      job: job,
      commit_sha: "abc123",
      grader_fingerprint: "grade-fingerprint",
      required: true,
      status: "passed"
    )
  end

  it "records timeout conclusions without making them reusable" do
    fingerprint = "timeout-fingerprint"
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, fingerprint)
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: {
        "name" => "react-tests",
        "required" => true,
        "exit_code" => 1,
        "duration_s" => 5.0,
        "timed_out" => false,
        "output" => "Error: Test timed out in 5000ms."
      }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /required graders failed/)

    conclusions = GraderConclusion.where(workflow: workflow).pluck(:grader_name, :status).to_h
    expect(conclusions).to include(
      "react-tests" => "timed_out",
      GraderConclusion::AGGREGATE_NAME => "timed_out"
    )
    expect(GraderConclusionCache.successful?(
      repository: job.repository,
      commit_sha: "abc123",
      grader_fingerprint: fingerprint
    )).to be(false)
  end

  it "passes when only optional graders fail" do
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: { "name" => "lint", "required" => false, "exit_code" => 1 }
    )

    expect { handler.call }.not_to raise_error

    iteration = workflow.reload.artifact("iterations").first
    expect(iteration).to include(
      include("name" => "lint", "required" => false, "status" => "failed")
    )
  end

  it "fails collection when any required grader fails" do
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")
  end

  it "records a reusable validation artifact when required graders pass" do
    handler.call

    expect(workflow.reload.artifact(LandingValidationCache::ARTIFACT_KEY)).to include(
      "required_graders_passed" => true,
      "head_sha" => "abc123",
      "tree_sha" => "abc123",
      "base_sha" => "abc123",
      "base_ref" => job.effective_base_branch
    )
  end

  it "records auto_merge base semantics on the landing validation artifact" do
    job.update!(mergeability_base_sha: "base123", mergeability_base_ref: "main")
    workflow.update!(trigger_kind: "auto_merge")

    handler.call

    expect(workflow.reload.artifact(LandingValidationCache::ARTIFACT_KEY)).to include(
      "head_sha" => "abc123",
      "base_sha" => "base123",
      "base_ref" => "main"
    )
  end

  it "records merge_train integration branch base semantics on the landing validation artifact" do
    epic = Factories.epic(user: job.user, repository: job.repository)
    train = MergeTrain.create!(epic: epic, repository: job.repository, base_branch: "master")
    workflow.update!(trigger_kind: "merge_train")
    workflow.set_artifact!("merge_train_id", train.id)
    workflow.set_artifact!("merge_train_base_sha", "trainbase123")

    handler.call

    expect(workflow.reload.artifact(LandingValidationCache::ARTIFACT_KEY)).to include(
      "head_sha" => "abc123",
      "base_sha" => "trainbase123",
      "base_ref" => "master"
    )
  end

  describe "current_head_sha artifact-first lookup" do
    it "reads HEAD SHA from the workflow artifact when ARTIFACT_HEAD_SHA_KEY is present" do
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, "artifact-sha")
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "fp")

      handler.call

      expect(GraderConclusion.where(workflow: workflow, grader_name: "tests").sole.commit_sha).to eq("artifact-sha")
    end

    it "does not call git rev-parse HEAD when ARTIFACT_HEAD_SHA_KEY is present" do
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, "artifact-sha")

      git = instance_double(GitRunner)
      allow(GitRunner).to receive(:new).and_return(git)
      expect(git).not_to receive(:run).with("rev-parse", "HEAD", chdir: anything)

      handler.call
    end

    it "falls back to git rev-parse HEAD when ARTIFACT_HEAD_SHA_KEY is absent" do
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "fp")
      # ARTIFACT_HEAD_SHA_KEY is not set — before block's git double returns "abc123\n"

      handler.call

      expect(GraderConclusion.where(workflow: workflow, grader_name: "tests").sole.commit_sha).to eq("abc123")
    end
  end

  describe "cache-write logging" do
    it "logs that the grader conclusion was cached when SHA and grader steps are present" do
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, "abc123def")
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "grade-fingerprint")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("grader conclusion cached for abc123d")
      expect(chunks).to include("fingerprint: grade-fi")
    end

    it "logs that the grader conclusion was not cached when SHA is unavailable" do
      git = instance_double(GitRunner)
      allow(GitRunner).to receive(:new).and_return(git)
      allow(git).to receive(:run).and_raise(StandardError, "git gone")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("grader conclusion NOT cached")
      expect(chunks).to include("sha=nil")
    end
  end

  it "copies timeout metadata into iteration artifacts" do
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: {
        "name" => "react-tests",
        "required" => true,
        "exit_code" => 1,
        "duration_s" => 5.0,
        "timed_out" => false,
        "output" => "Error: Test timed out in 5000ms."
      }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /required graders failed/)

    iteration = workflow.reload.artifact("iterations").first
    expect(iteration.first).to include(
      "name" => "react-tests",
      "timed_out" => false,
      "output" => "Error: Test timed out in 5000ms."
    )
  end

  it "records grader loop timing without fanout-specific fields" do
    base_time = Time.zone.parse("2026-07-31 12:00:00 UTC")
    workflow.steps.where(kind: "grader").delete_all
    [
      [ "alpha", base_time, base_time + 0.30.seconds ],
      [ "beta", base_time + 0.02.seconds, base_time + 0.32.seconds ],
      [ "gamma", base_time + 0.04.seconds, base_time + 0.34.seconds ]
    ].each_with_index do |(name, started_at, finished_at), index|
      Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 100 + index,
        iteration: 1,
        loop_id: loop_id,
        state: "succeeded",
        started_at: started_at,
        finished_at: finished_at,
        details: { "name" => name, "required" => true, "duration_s" => 0.30 }
      )
    end

    handler.call

    measurement = workflow.reload.artifact("grader_loops").first
    expect(measurement).to include(
      "iteration" => 1,
      "grader_count" => 3,
      "wall_clock_s" => be_within(0.001).of(0.34),
      "summed_duration_s" => be_within(0.001).of(0.9),
      "failed_required_count" => 0
    )
    metrics = workflow.artifact(LandingThroughputMetrics::ARTIFACT_KEY).dig("grader_loops").first
    expect(metrics).to include(
      "iteration" => 1,
      "grader_count" => 3,
      "wall_clock_s" => be_within(0.001).of(0.34),
      "summed_duration_s" => be_within(0.001).of(0.9),
      "failed_required_count" => 0,
      "outcome" => "passed"
    )
    expect(metrics).not_to have_key("cap")
    expect(metrics).not_to have_key("parallelism_speedup")
    expect(metrics).not_to have_key("parallelism_efficiency")
    expect(run.reload.job_logs.pluck(:chunk).join("\n")).to include("grader wall-clock 0.3s vs summed duration 0.9s")
  end

  it "records failed grader loop metrics before raising" do
    base_time = Time.zone.parse("2026-07-31 12:00:00 UTC")
    workflow.update!(trigger_kind: "auto_merge")
    workflow.steps.where(kind: "grader").delete_all
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 100,
      iteration: 1,
      loop_id: loop_id,
      state: "failed",
      started_at: base_time,
      finished_at: base_time + 0.5.seconds,
      details: { "name" => "rspec", "required" => true, "duration_s" => 0.5 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")

    metrics = workflow.reload.artifact(LandingThroughputMetrics::ARTIFACT_KEY).dig("grader_loops").first
    expect(metrics).to include(
      "iteration" => 1,
      "grader_count" => 1,
      "failed_required_count" => 1,
      "outcome" => "failed"
    )
    expect(metrics).not_to have_key("cap")
  end
end
