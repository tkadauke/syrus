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
      details: {
        "name" => "tests",
        "target_label" => "//cli:grade/tests",
        "command" => "bundle exec rspec",
        "required" => true,
        "timeout_minutes" => 15,
        "prepare_targets" => [
          { "target_label" => "//cli:prepare", "commands" => [ "bundle install" ] }
        ],
        "prepare_commands" => [ "bundle install" ],
        "source_snapshot_id" => 101,
        "source_snapshot" => {
          "id" => 101,
          "source_sha" => "abc123",
          "tree_sha" => "tree456"
        },
        "duration_s" => 12.3,
        "log_path" => "logs/tests.log",
        "log_bytes" => 1234
      }
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

    target_health = TargetHealthRecord.where(workflow: workflow, target_label: "//cli:grade/tests").sole
    expect(target_health).to have_attributes(
      repository: job.repository,
      step: per_grader.step,
      run: per_grader.run,
      project_id: "cli",
      commit_sha: "abc123",
      input_fingerprint: "tree456",
      status: "passed",
      duration_s: 12.3,
      log_path: "logs/tests.log",
      log_bytes: 1234
    )
    expect(target_health.command_fingerprint).to be_present
    expect(target_health.environment_fingerprint).to be_present
    expect(target_health.artifacts).to include("log_path" => "logs/tests.log", "log_bytes" => 1234)
    expect(workflow.reload.artifact(TargetHealthRecorder::WORKFLOW_ARTIFACT_KEY)).to include(
      include(
        "target_health_record_id" => target_health.id,
        "target_label" => "//cli:grade/tests",
        "project_id" => "cli",
        "commit_sha" => "abc123",
        "status" => "passed"
      )
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

  # Rung 0 records what it decided even when nothing acts on it, so the
  # escalations-per-landing metric has something to count.
  it "records the rung-0 verdict alongside the failure" do
    workflow.steps.find_by!(kind: "grader").update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    expect(workflow.reload.artifact("rung_zero_adjudication")).to include(
      "verdict" => "inconclusive", "reason" => "no_adjudicator_decided"
    )
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

  it "records grader loop timing and rollout metrics" do
    base_time = Time.zone.parse("2026-07-31 12:00:00 UTC")
    workflow.steps.where(kind: "grader").delete_all
    grader_steps = [
      [ "alpha", base_time, base_time + 0.30.seconds ],
      [ "beta", base_time + 0.02.seconds, base_time + 0.32.seconds ],
      [ "gamma", base_time + 0.04.seconds, base_time + 0.34.seconds ]
    ].each_with_index.map do |(name, started_at, finished_at), index|
      Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 100 + index,
        iteration: 1,
        loop_id: loop_id,
        state: "succeeded",
        started_at: started_at,
        finished_at: finished_at,
        details: {
          "name" => name,
          "required" => true,
          "duration_s" => 0.30,
          "prepare_cache" => { "status" => index.zero? ? "miss" : "hit" }
        }
      )
    end
    grader_steps.each_with_index do |grader_step, index|
      grader_run = grader_step.runs.create!(
        job: job,
        trigger_kind: workflow.trigger_kind,
        state: "succeeded",
        created_at: base_time - (index + 1).seconds,
        started_at: grader_step.started_at,
        finished_at: grader_step.finished_at
      )
      WorkflowStepWorkerSlot.create!(
        workflow: workflow,
        step: grader_step,
        run: grader_run,
        worker_key: "storage:worker-#{index % 2}",
        worker_storage_key: "worker-#{index % 2}",
        worker_hostname: "host-#{index % 2}",
        released_at: Time.current,
        release_reason: "run_terminal"
      )
    end

    handler.call

    measurement = workflow.reload.artifact("grader_loops").first
    expect(measurement).to include(
      "iteration" => 1,
      "grader_count" => 3,
      "wall_clock_s" => be_within(0.001).of(0.34),
      "summed_duration_s" => be_within(0.001).of(0.9),
      "failed_required_count" => 0,
      "queue_wait_avg_s" => be_within(0.001).of(2.02),
      "queue_wait_max_s" => be_within(0.001).of(3.04),
      "worker_spread" => 2,
      "worker_keys" => contain_exactly("storage:worker-0", "storage:worker-1"),
      "prepare_cache_hits" => 2,
      "prepare_cache_misses" => 1,
      "source_snapshot_mismatch_count" => 0,
      "infrastructure_failure_count" => 0
    )
    metrics = workflow.artifact(LandingThroughputMetrics::ARTIFACT_KEY).dig("grader_loops").first
    expect(metrics).to include(
      "iteration" => 1,
      "grader_count" => 3,
      "wall_clock_s" => be_within(0.001).of(0.34),
      "summed_duration_s" => be_within(0.001).of(0.9),
      "failed_required_count" => 0,
      "outcome" => "passed",
      "queue_wait_avg_s" => be_within(0.001).of(2.02),
      "queue_wait_max_s" => be_within(0.001).of(3.04),
      "worker_spread" => 2,
      "prepare_cache_hits" => 2,
      "prepare_cache_misses" => 1,
      "source_snapshot_mismatch_count" => 0,
      "infrastructure_failure_count" => 0
    )
    expect(metrics).not_to have_key("cap")
    expect(metrics).not_to have_key("parallelism_speedup")
    expect(metrics).not_to have_key("parallelism_efficiency")
    expect(run.reload.job_logs.pluck(:chunk).join("\n")).to include(
      "grader wall-clock 0.3s vs summed duration 0.9s; worker spread 2 worker(s); queue wait avg 2.02s max 3.04s"
    )
  end

  it "records source snapshot and infrastructure failure counts for failed immutable graders" do
    base_time = Time.zone.parse("2026-07-31 12:00:00 UTC")
    workflow.steps.where(kind: "grader").delete_all
    grader_step = Step.create!(
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
    grader_run = grader_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      state: "failed",
      created_at: base_time - 2.seconds,
      started_at: base_time,
      finished_at: base_time + 0.5.seconds
    )
    grader_run.create_run_failure_classification!(
      classification: "source_snapshot_metadata_invalid",
      confidence: 0.95,
      retryable: true,
      reason: "Workflow source snapshot metadata is missing.",
      classified_at: Time.current
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")

    metrics = workflow.reload.artifact("grader_loops").first
    expect(metrics).to include(
      "source_snapshot_mismatch_count" => 1,
      "infrastructure_failure_count" => 1,
      "queue_wait_avg_s" => 2.0,
      "queue_wait_max_s" => 2.0
    )
  end

  it "batch-loads rollout metric inputs for grader batches" do
    base_time = Time.zone.parse("2026-07-31 12:00:00 UTC")
    workflow.steps.where(kind: "grader").delete_all
    grader_steps = 6.times.map do |index|
      Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 100 + index,
        iteration: 1,
        loop_id: loop_id,
        state: "succeeded",
        started_at: base_time + index.seconds,
        finished_at: base_time + index.seconds + 0.5.seconds,
        details: { "name" => "grader-#{index}", "required" => true, "duration_s" => 0.5 }
      )
    end
    grader_steps.each do |grader_step|
      grader_run = grader_step.runs.create!(
        job: job,
        trigger_kind: workflow.trigger_kind,
        state: "succeeded",
        created_at: base_time - 1.second,
        started_at: grader_step.started_at,
        finished_at: grader_step.finished_at
      )
      grader_run.create_run_failure_classification!(
        classification: "grader_failure",
        confidence: 0.9,
        retryable: false,
        reason: "not used for passed rollout metrics",
        classified_at: Time.current
      )
      WorkflowStepWorkerSlot.create!(
        workflow: workflow,
        step: grader_step,
        run: grader_run,
        worker_key: "storage:worker-#{grader_step.id}",
        worker_storage_key: "worker-#{grader_step.id}",
        released_at: Time.current,
        release_reason: "run_terminal"
      )
    end

    queries = capture_sql { handler.call }

    expect(selects_from(queries, "runs").grep(/"runs"\."step_id" IN/).size).to eq(1)
    expect(selects_from(queries, "workflow_step_worker_slots").grep(/"workflow_step_worker_slots"\."step_id" IN/).size).to eq(1)
    expect(selects_from(queries, "run_failure_classifications").size).to eq(1)
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

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA"

      queries << sql
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def selects_from(queries, table_name)
    queries.grep(/\ASELECT\b.*FROM "#{table_name}"/i)
  end
end
