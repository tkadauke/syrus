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

  it "passes allow-inherited grader failures that match broken-main grader evidence" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    base_workflow = Workflow.create!(job: job, trigger_kind: "main_grader")
    base_step = Step.create!(
      workflow: base_workflow,
      kind: "grader",
      position: 1,
      state: "failed",
      details: { "name" => "rspec", "output" => "same build failure" }
    )
    base_run = base_step.runs.create!(job: job, trigger_kind: "main_grader", state: "failed")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: base_workflow,
      step: base_step,
      run: base_run,
      commit_sha: "main123",
      grader_fingerprint: "base-fp",
      grader_name: "rspec",
      required: true,
      status: "failed",
      checked_at: Time.current
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "rspec" ]
    )
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "failures" => "allow_inherited", "exit_code" => 1, "output" => "same build failure" }
    )

    expect { handler.call }.not_to raise_error

    artifact = workflow.reload.artifact("inherited_main_branch_grader_failure")
    expect(artifact).to include(
      "failed_names" => [ "rspec" ],
      "evidence" => include("sha" => "main123", "failed_names" => [ "rspec" ])
    )
    expect(artifact["classifications"].first).to include(
      "failures" => "allow_inherited",
      "reason" => "output_fingerprint_matches_base"
    )
    expect(run.reload.job_logs.pluck(:chunk).join("\n")).to include("treating as inherited: rspec")
  end

  it "does not pass strict grader failures even when main has the same failed grader" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "eager-load" ]
    )
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: { "name" => "eager-load", "required" => true, "failures" => "strict", "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: eager-load")
  end

  it "passes test-case grader failures only when failed cases match the base revision" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    base_workflow = Workflow.create!(job: job, trigger_kind: "main_grader")
    base_step = Step.create!(workflow: base_workflow, kind: "grader", position: 1, state: "failed", details: { "name" => "rspec", "failures" => "allow_inherited" })
    base_run = base_step.runs.create!(job: job, trigger_kind: "main_grader", state: "failed")
    base_test_run = TestRun.create!(run: base_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestCase.create!(test_run: base_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "Widget fails", status: "failed")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: base_workflow,
      step: base_step,
      run: base_run,
      commit_sha: "main123",
      grader_fingerprint: "base-fp",
      grader_name: "rspec",
      required: true,
      status: "failed",
      checked_at: Time.current
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "rspec" ]
    )
    grader_step = workflow.steps.find_by!(kind: "grader")
    candidate_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
    candidate_test_run = TestRun.create!(run: candidate_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestCase.create!(test_run: candidate_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "Widget fails", status: "failed")
    grader_step.update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "failures" => "allow_inherited", "junit_output" => "tmp/rspec.xml", "exit_code" => 1 }
    )

    expect { handler.call }.not_to raise_error

    classification = workflow.reload.artifact("inherited_main_branch_grader_failure")["classifications"].first
    expect(classification).to include(
      "failures" => "allow_inherited",
      "reason" => "failed_cases_match_base",
      "candidate_failed_case_count" => 1,
      "base_failed_case_count" => 1
    )
  end

  it "does not pass test-case grader failures that introduce a new failed case" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    base_workflow = Workflow.create!(job: job, trigger_kind: "main_grader")
    base_step = Step.create!(workflow: base_workflow, kind: "grader", position: 1, state: "failed", details: { "name" => "rspec", "failures" => "allow_inherited" })
    base_run = base_step.runs.create!(job: job, trigger_kind: "main_grader", state: "failed")
    base_test_run = TestRun.create!(run: base_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestCase.create!(test_run: base_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "Old failure", status: "failed")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: base_workflow,
      step: base_step,
      run: base_run,
      commit_sha: "main123",
      grader_fingerprint: "base-fp",
      grader_name: "rspec",
      required: true,
      status: "failed",
      checked_at: Time.current
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "rspec" ]
    )
    grader_step = workflow.steps.find_by!(kind: "grader")
    candidate_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
    candidate_test_run = TestRun.create!(run: candidate_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestCase.create!(test_run: candidate_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "New failure", status: "failed")
    grader_step.update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "failures" => "allow_inherited", "junit_output" => "tmp/rspec.xml", "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")
  end

  it "does not pass new grader failures that are absent from broken-main evidence" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "eslint" ]
    )
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "failures" => "allow_inherited", "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")
  end

  it "does not pass inherited-looking grader failures under strict failure policy" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "rspec" ]
    )
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "failures" => "strict", "exit_code" => 1 }
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

  it "notifies the landing validation prefetcher after auto_merge graders pass" do
    job.update!(state: "landing", mergeability_base_sha: "base123", mergeability_base_ref: "main")
    workflow.update!(trigger_kind: "auto_merge")
    allow(LandingValidationPrefetcher).to receive(:after_landing_graders_passed)

    handler.call

    expect(LandingValidationPrefetcher).to have_received(:after_landing_graders_passed).with(workflow: workflow)
  end

  it "records speculative landing base tree semantics on the validation artifact" do
    workflow.update!(trigger_kind: "landing_validation")
    workflow.set_artifact!("predicted_base_sha", "predicted-base")
    workflow.set_artifact!("predicted_base_tree_sha", "predicted-tree")
    workflow.set_artifact!("predicted_base_ref", "main")

    handler.call

    expect(workflow.reload.artifact(LandingValidationCache::ARTIFACT_KEY)).to include(
      "head_sha" => "abc123",
      "base_sha" => "predicted-base",
      "base_tree_sha" => "predicted-tree",
      "base_ref" => "main",
      "validation_source" => "speculative_landing"
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

  describe "grade.rerun_only_failed carry-forward" do
    def carried_forward_entry(name: "lint", required: true)
      {
        "name" => name,
        "required" => required,
        "source_iteration" => 0,
        "exit_code" => 0,
        "duration_s" => 1.2,
        "log_path" => ".syrus/grade-output/iteration-1/#{name}.log",
        "log_bytes" => 42,
        "output" => "ok"
      }
    end

    it "still counts a carried-forward required grader as passing even though it has no Step this iteration" do
      workflow.set_artifact!(Steps::GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY, [ carried_forward_entry ])

      expect { handler.call }.not_to raise_error

      iteration = workflow.reload.artifact("iterations").first
      expect(iteration).to include(
        include("name" => "tests", "status" => "passed"),
        include("name" => "lint", "status" => "passed", "carried_forward" => true)
      )
    end

    it "records a per-iteration GraderConclusion for the carried-forward grader so history has no gap" do
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "grade-fingerprint")
      workflow.set_artifact!(Steps::GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY, [ carried_forward_entry ])

      expect { handler.call }.to change(GraderConclusion, :count).by(3)

      carried = GraderConclusion.where(workflow: workflow, grader_name: "lint").sole
      expect(carried).to have_attributes(
        repository: job.repository,
        job: job,
        commit_sha: "abc123",
        grader_fingerprint: "grade-fingerprint",
        required: true,
        status: "passed"
      )
      expect(carried.metadata).to include("carried_forward" => true, "source_iteration" => 0)
    end

    it "still succeeds when every active grader is carried forward and none has a Step this iteration" do
      workflow.steps.where(kind: "grader").delete_all
      workflow.set_artifact!(Steps::GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY, [ carried_forward_entry ])

      expect { handler.call }.not_to raise_error

      iteration = workflow.reload.artifact("iterations").first
      expect(iteration.size).to eq(1)
      expect(iteration).to include(
        include("name" => "lint", "status" => "passed", "carried_forward" => true)
      )
    end
  end
end
