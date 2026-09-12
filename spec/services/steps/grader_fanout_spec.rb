require "rails_helper"
require "tmpdir"

RSpec.describe Steps::GraderFanout, :ci_only do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:loop_id)  { SecureRandom.uuid }

  let(:collect_step) do
    Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 102,
      iteration: 1,
      loop_id: loop_id
    )
  end

  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader_fanout",
      position: 101,
      iteration: 1,
      loop_id: loop_id,
      next_step_id: collect_step.id
    )
  end

  # The grader-conclusion cache tests refer to the fanout/collect steps by
  # these names.
  let(:fanout)  { step }
  let(:collect) { collect_step }

  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-grader-fanout") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    collect_step  # ensure the continuation step exists before the fanout step
    step          # and the fanout step itself

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: "origin/main", branch_name: "syrus/direct-1")
    allow(handler).to receive(:workspace).and_return(fake_ws)

    # One shared GitRunner double: current_head_sha reads `rev-parse HEAD`
    # (drives the grader-conclusion cache) and changed_files reads
    # `diff --name-only` (drives the when_files_changed skip). Tests override the
    # diff behavior via stub_changed_files; the rev-parse stub persists.
    @git = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(@git)
    allow(@git).to receive(:run).with("rev-parse", "HEAD", chdir: anything).and_return("abc123\n")
    allow(@git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: anything).and_return("tree123\n")
    allow(@git).to receive(:run).with("diff", "--name-only", anything, chdir: anything).and_return("")
    allow(GithubAuthenticatedGit).to receive(:run) { |**_, &block| block.call("file://remote") }
    allow(@git).to receive(:run)
      .with("push", "file://remote", /\Aabc123:refs\/syrus\/source-snapshots\/runs\/\d+\z/, chdir: anything, env: { "GIT_TERMINAL_PROMPT" => "0" })
      .and_return("")
  end

  def write_config(contents)
    File.write(@ws_path.join(".syrus.yml"), contents)
  end

  def write_grade_config(command)
    @ws_path.join(".syrus.yml").write(<<~YAML)
      grade:
        steps:
          - name: tests
            run: #{command}
    YAML
  end

  def stub_changed_files(*files)
    allow(@git).to receive(:run).with("diff", "--name-only", anything, chdir: anything).and_return(files.join("\n"))
  end

  def current_fingerprint
    GraderConclusionCache.fingerprint_for_plan(
      LandingGraderPlan.effective(RepoGradePlan.for(@ws_path), trigger_kind: workflow.trigger_kind, iteration: run.iteration),
      target_graph: TargetGraph::Compiler.compile(@ws_path)
    )
  end

  def record_target_health(label, status: "passed", checked_at: 1.minute.ago, overrides: {})
    graph = TargetGraph::Compiler.compile(@ws_path)
    target = graph.target(TargetGraph::Label.parse(label))
    fingerprints = TargetGraph::Fingerprints.for_target(
      workspace_path: @ws_path,
      graph: graph,
      label: target.label
    )

    TargetHealthRecorder.record!(
      repository: job.repository,
      target_label: target.label.to_s,
      project_id: target.project_id,
      commit_sha: overrides.fetch(:commit_sha, "previous123"),
      input_fingerprint: overrides.fetch(:input_fingerprint, fingerprints.input_fingerprint),
      command_fingerprint: overrides.fetch(:command_fingerprint, fingerprints.command_fingerprint),
      environment_fingerprint: overrides.fetch(:environment_fingerprint, fingerprints.environment_fingerprint),
      status: status,
      checked_at: checked_at
    )
  end

  # --- when_files_changed skip (PR #41) ---------------------------------

  it "materializes graders without when_files_changed regardless of changed files" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader")
    expect(grader_steps.count).to eq(1)
    expect(grader_steps.first.details["name"]).to eq("rspec")
  end

  it "records target selection inputs for initial workflows so later CI repair can diagnose skipped targets" do
    write_config(<<~YAML)
      grade:
        - name: app-tests
          run: bin/rspec spec/app
          when_files_changed: ["app/**/*.rb"]
        - name: docs-tests
          run: bin/check-docs
          when_files_changed: ["docs/**/*.md"]
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    expect(workflow.artifact(Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY)).to contain_exactly(
      include("name" => "app-tests", "target_label" => "//:grade/app-tests", "affected" => true),
      include("name" => "docs-tests", "target_label" => "//:grade/docs-tests", "affected" => false)
    )
    expect(step.reload.details[Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY]).to contain_exactly(
      include("name" => "app-tests", "target_label" => "//:grade/app-tests", "affected" => true),
      include("name" => "docs-tests", "target_label" => "//:grade/docs-tests", "affected" => false)
    )
  end

  it "retries transient step materialization deadlocks" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    calls = 0
    allow(Step).to receive(:transaction).and_wrap_original do |original, *args, &block|
      calls += 1
      raise ActiveRecord::Deadlocked, "deadlock" if calls == 1

      original.call(*args, &block)
    end

    handler.call

    expect(calls).to eq(2)
    expect(workflow.steps.where(kind: "grader").count).to eq(1)
  end

  it "keeps materialized grader Steps pinned and detail-compatible when the distributed gate is off" do
    job.repository.update!(distributed_workflow_dag_enabled: true)
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    grader_step = workflow.steps.find_by!(kind: "grader")
    expect(grader_step.placement_policy).to eq(Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE)
    expect(grader_step.details).not_to include(
      "projected_target_label",
      "projected_target_fingerprint",
      "projected_resource_key",
      "barrier_group",
      "barrier_labels",
      "source_snapshot_id",
      "source_snapshot"
    )
    expect(workflow.source_snapshots).to be_empty
  end

  it "records immutable placement and descriptive DAG metadata for materialized graders when distributed workflows are enabled" do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    job.repository.update!(distributed_workflow_dag_enabled: true)
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: true)
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    grader_step = workflow.steps.find_by!(kind: "grader")
    snapshot = workflow.source_snapshots.first
    expect(grader_step.placement_policy).to eq(Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)
    expect(grader_step.details).to include(
      "projected_target_label" => "//:grade/rspec",
      "projected_resource_key" => "target://:grade/rspec",
      "barrier_group" => "workflow:#{workflow.id}:loop:#{loop_id}:iteration:1:grader_collect",
      "barrier_labels" => [ "grader_collect" ],
      "source_snapshot_id" => snapshot.id
    )
    expect(grader_step.details["projected_target_fingerprint"]).to match(/\A[0-9a-f]{64}\z/)
    expect(grader_step.details["source_snapshot"]).to include(
      "id" => snapshot.id,
      "source_sha" => "abc123",
      "source_ref" => "refs/syrus/source-snapshots/runs/#{run.id}",
      "tree_sha" => "tree123"
    )
  end

  it "projects legacy graders as parallel siblings behind a collect barrier when worker-slot admission is enabled" do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    job.repository.update!(distributed_workflow_dag_enabled: true)
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: true)
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
        - name: lint
          run: bin/rubocop
    YAML

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position).to_a
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec lint])
    expect(step.reload.next_step_id).to eq(grader_steps.first.id)
    expect(grader_steps.map(&:next_step_id)).to eq([ collect.id, collect.id ])
    expect(grader_steps.map(&:depends_on_step_ids)).to eq([ [ step.id ], [ step.id ] ])
    expect(collect.reload.depends_on_step_ids).to eq(grader_steps.map(&:id))
  end

  it "falls back to pinned serial in-workflow grading until worker-slot admission is enabled" do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    job.repository.update!(distributed_workflow_dag_enabled: true)
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: false)
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
        - name: lint
          run: bin/rubocop
    YAML

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position).to_a
    expect(grader_steps.map(&:placement_policy)).to eq([
      Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE,
      Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    ])
    expect(grader_steps.map { |s| s.details["source_snapshot_id"] }).to all(be_nil)
    expect(workflow.source_snapshots).to be_empty
    expect(step.reload.next_step_id).to eq(grader_steps.first.id)
    expect(grader_steps.first.next_step_id).to eq(grader_steps.second.id)
    expect(grader_steps.second.next_step_id).to eq(collect.id)
    expect(collect.reload.depends_on_step_ids).to eq(grader_steps.map(&:id))
  end

  it "prefers a published checkpoint ref for the current source snapshot" do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    job.repository.update!(distributed_workflow_dag_enabled: true)
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: true)
    implement_step = Step.create!(
      workflow: workflow,
      kind: "implement",
      position: 100,
      state: "succeeded",
      started_at: 1.minute.ago,
      finished_at: 30.seconds.ago
    )
    implement_run = implement_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      state: "succeeded",
      head_sha: "abc123"
    )
    RunCheckpoint.create!(
      run: implement_run,
      workflow: workflow,
      step: implement_step,
      job: job,
      repository: job.repository,
      user: job.user,
      step_kind: "implement",
      commit_sha: "abc123",
      base_sha: "base123",
      remote_ref: "refs/syrus/checkpoints/runs/#{implement_run.id}",
      status: "published",
      published_at: Time.current
    )
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    expect(@git).not_to receive(:run).with("push", anything, anything, chdir: anything, env: anything)

    handler.call

    snapshot = workflow.source_snapshots.sole
    expect(snapshot.source_ref).to eq("refs/syrus/checkpoints/runs/#{implement_run.id}")
    expect(workflow.steps.find_by!(kind: "grader").details["source_snapshot"]).to include(
      "source_ref" => "refs/syrus/checkpoints/runs/#{implement_run.id}"
    )
  end

  it "reuses the current workflow source snapshot for all materialized graders when distributed workflows are enabled" do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    job.repository.update!(distributed_workflow_dag_enabled: true)
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: true)
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
        - name: lint
          run: bin/rubocop
    YAML

    handler.call

    snapshot_ids = workflow.steps.where(kind: "grader").order(:position).map { |s| s.details["source_snapshot_id"] }
    expect(snapshot_ids).to eq([ workflow.source_snapshots.sole.id, workflow.source_snapshots.sole.id ])
  end

  it "uses review-phase graders on the first implementation validation pass" do
    write_config(<<~YAML)
      grade:
        - name: smoke
          run: bin/smoke
          phases: [review]
        - name: rspec
          run: bin/rspec
          phases: [landing]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("smoke")
    expect(details["command"]).to eq("bin/smoke")
    expect(details["phase"]).to eq("review")
    expect(details["configured_phases"]).to eq([ "review" ])
  end

  it "uses landing-phase graders for landing validations" do
    workflow.update!(trigger_kind: "auto_merge")
    write_config(<<~YAML)
      grade:
        - name: smoke
          run: bin/smoke
          phases: [review]
        - name: rspec
          run: bin/rspec
          phases: [landing]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec")
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("landing")
  end

  it "uses landing-phase graders for speculative landing validations" do
    workflow.update!(trigger_kind: "landing_validation")
    write_config(<<~YAML)
      grade:
        - name: smoke
          run: bin/smoke
          phases: [review]
        - name: rspec
          run: bin/rspec
          phases: [landing]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec")
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("landing")
  end

  it "computes changed files from the predicted base for speculative landing validations" do
    workflow.update!(trigger_kind: "landing_validation")
    workflow.set_artifact!("predicted_base_sha", "predicted-base")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          when_files_changed:
            - app/**/*.rb
    YAML

    expect(@git).to receive(:run)
      .with("diff", "--name-only", "predicted-base...HEAD", chdir: @ws_path.to_s)
      .and_return("app/models/job.rb\n")

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
    expect(run.reload.job_logs.pluck(:chunk).join("\n")).to include(
      "computing affected landing targets from predicted base predict"
    )
  end

  it "computes auto-merge affected targets from the current mergeability base" do
    workflow.update!(trigger_kind: "auto_merge")
    job.update!(mergeability_base_sha: "current-base-sha")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          when_files_changed:
            - app/**/*.rb
    YAML

    expect(@git).to receive(:run)
      .with("diff", "--name-only", "current-base-sha...HEAD", chdir: @ws_path.to_s)
      .and_return("app/models/job.rb\n")

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("computing affected landing targets from current base current")
    expect(chunks).to include("selected rspec (own source scope matched a changed file) [//:grade/rspec]")
  end

  it "forces unaffected required landing targets when reusable target health is missing" do
    workflow.update!(trigger_kind: "auto_merge")
    job.update!(mergeability_base_sha: "current-base-sha")
    write_config(<<~YAML)
      grade:
        - name: app-tests
          run: bin/rspec spec/app
          required: true
          when_files_changed:
            - app/**
        - name: docs-tests
          run: bin/check-docs
          required: true
          when_files_changed:
            - docs/**
    YAML
    stub_changed_files("app/models/job.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[app-tests docs-tests])
    expect(workflow.reload.artifact(Steps::GraderFanout::TARGET_HEALTH_FORCED_ARTIFACT_KEY)).to include(
      include("name" => "docs-tests", "target_label" => "//:grade/docs-tests", "reason" => "target health is unknown")
    )
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("skipped docs-tests (no matching files changed) [//:grade/docs-tests]")
    expect(chunks).to include("forced validation for docs-tests (target health is unknown) [//:grade/docs-tests]")
  end

  it "keeps unaffected required landing targets skipped when reusable target health passes" do
    workflow.update!(trigger_kind: "auto_merge")
    job.update!(mergeability_base_sha: "current-base-sha")
    write_config(<<~YAML)
      grade:
        - name: app-tests
          run: bin/rspec spec/app
          required: true
          when_files_changed:
            - app/**
        - name: docs-tests
          run: bin/check-docs
          required: true
          when_files_changed:
            - docs/**
    YAML
    stub_changed_files("app/models/job.rb")
    health = record_target_health("//:grade/docs-tests", status: "passed")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[app-tests])
    expect(workflow.reload.artifact(Steps::GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY)).to include(
      include(
        "name" => "docs-tests",
        "target_label" => "//:grade/docs-tests",
        "target_health_record_id" => health.id
      )
    )
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("skipped docs-tests (no matching files changed) [//:grade/docs-tests]")
    expect(chunks).to include("skipped docs-tests (latest target health record passed from previou) [//:grade/docs-tests]")
  end

  it "computes merge-train affected targets from the built integration base" do
    workflow.update!(trigger_kind: "merge_train")
    workflow.set_artifact!("merge_train_base_sha", "train-base-sha")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          when_files_changed:
            - app/**/*.rb
    YAML

    expect(@git).to receive(:run)
      .with("diff", "--name-only", "train-base-sha...HEAD", chdir: @ws_path.to_s)
      .and_return("app/models/job.rb\n")

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
    expect(run.reload.job_logs.pluck(:chunk).join("\n")).to include(
      "computing affected landing targets from current base train-b"
    )
  end

  it "uses explicit CI-phase graders for CI failure validations" do
    workflow.update!(trigger_kind: "ci_failure")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          phases: [landing]
        - name: rspec-ci
          run: RUN_CI_ONLY_SPECS=true bin/rspec
          phases: [ci]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec-ci")
    expect(details["command"]).to eq("RUN_CI_ONLY_SPECS=true bin/rspec")
    expect(details["phase"]).to eq("ci")
  end

  it "expands a legacy ci command into a CI-phase grader" do
    workflow.update!(trigger_kind: "main_grader")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          ci: bin/rspec-ci
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec-ci")
    expect(details["command"]).to eq("bin/rspec-ci")
    expect(details["phase"]).to eq("ci")
    expect(details["legacy_ci_command"]).to be true
    expect(details["legacy_source_grader"]).to eq("rspec")
  end

  it "uses all-phase graders for main branch graders when no CI-specific grader is configured" do
    workflow.update!(trigger_kind: "main_grader")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("ci")
  end

  it "selects main branch grader targets affected since the previous main SHA" do
    workflow.update!(trigger_kind: "main_grader")
    workflow.set_artifact!("previous_main_sha", "oldmain123")
    write_config(<<~YAML)
      grade:
        - name: app-tests
          run: bin/rspec spec/models
          when_files_changed:
            - "app/**"
        - name: docs-tests
          run: bin/check-docs
          when_files_changed:
            - "docs/**"
    YAML
    expect(@git).to receive(:run)
      .with("diff", "--name-only", "oldmain123...HEAD", chdir: @ws_path.to_s)
      .and_return("app/models/job.rb\n")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq([ "app-tests" ])
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("computing affected targets from previous main SHA oldmain")
    expect(chunks).to include("selected app-tests (own source scope matched a changed file) [//:grade/app-tests]")
    expect(chunks).to include("skipped docs-tests (no matching files changed) [//:grade/docs-tests]")
  end

  it "runs all main branch grader targets when no previous main SHA exists" do
    workflow.update!(trigger_kind: "main_grader")
    write_config(<<~YAML)
      grade:
        - name: app-tests
          run: bin/rspec spec/models
          when_files_changed:
            - "app/**"
        - name: docs-tests
          run: bin/check-docs
          when_files_changed:
            - "docs/**"
    YAML

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[app-tests docs-tests])
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("no previous main SHA recorded; baseline target health will run every configured grader")
    expect(chunks).to include("selected app-tests (baseline main target health has no previous SHA) [//:grade/app-tests]")
    expect(chunks).to include("selected docs-tests (baseline main target health has no previous SHA) [//:grade/docs-tests]")
  end

  it "does not reuse target health or cached grader conclusions during broad main branch sweeps" do
    workflow.update!(trigger_kind: "main_grader")
    write_config(<<~YAML)
      grade:
        - name: app-tests
          run: bin/rspec spec/models
          when_files_changed:
            - "app/**"
        - name: docs-tests
          run: bin/check-docs
          when_files_changed:
            - "docs/**"
    YAML
    record_target_health("//:grade/app-tests", status: "passed")
    record_target_health("//:grade/docs-tests", status: "passed")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: workflow,
      step: fanout,
      run: run,
      commit_sha: "abc123",
      grader_fingerprint: current_fingerprint,
      grader_name: GraderConclusion::AGGREGATE_NAME,
      required: true,
      status: "passed",
      checked_at: 1.hour.ago
    )

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[app-tests docs-tests])
    expect(workflow.reload.artifact(Steps::GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY)).to eq([])
    expect(workflow.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY)).to be_nil
  end

  it "uses all-phase graders in CI failure contexts when no CI-specific grader is configured" do
    workflow.update!(trigger_kind: "ci_failure")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("ci")
  end

  # Repos mid-upgrade may still declare `fast:`. It is parsed so the config
  # keeps loading, but it selects nothing.
  it "ignores a legacy fast command and uses run" do
    workflow.update!(trigger_kind: "auto_merge")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          fast: COVERAGE=false bin/rspec
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["command"]).to eq("bin/rspec")
    expect(details).not_to have_key("fast_command")
    expect(details).not_to have_key("fast_variant")
  end

  it "uses the same command on later grade-loop iterations" do
    step.update!(iteration: 2)
    collect.update!(iteration: 2)
    run.update!(iteration: 2)
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    expect(workflow.steps.find_by!(kind: "grader").details["command"]).to eq("bin/rspec")
  end

  it "materializes graders whose when_files_changed patterns match changed files" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("website/src/index.js", "app/models/user.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[website-build rspec])
  end

  it "does not materialize a duplicate grader batch when fanout is retried after inserting steps" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
        - name: react-tests
          run: bin/test-react
    YAML

    handler.call
    first_batch_ids = workflow.steps.where(kind: "grader").order(:position).pluck(:id)

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.pluck(:id)).to eq(first_batch_ids)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec react-tests])
  end

  it "skips graders whose when_files_changed patterns do not match any changed files" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec])
  end

  it "runs a grader when an explicitly-declared dependency target changed" do
    write_config(<<~YAML)
      targets:
        - name: library
          kind: library
          sources: ["lib/**"]
      grade:
        - name: library-tests
          run: bin/rspec spec/lib
          when_files_changed:
            - "spec/lib/**"
          deps: [":library"]
    YAML
    stub_changed_files("lib/service.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[library-tests])
    expect(grader_steps.first.details["target_label"]).to eq("//:grade/library-tests")
  end

  it "keeps skipping a dependency-aware grader when neither the grader nor dependency target changed" do
    write_config(<<~YAML)
      targets:
        - name: library
          kind: library
          sources: ["lib/**"]
      grade:
        - name: library-tests
          run: bin/rspec spec/lib
          when_files_changed:
            - "spec/lib/**"
          deps: [":library"]
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(0)
  end

  it "stores prepare dependency commands for the materialized grader" do
    write_config(<<~YAML)
      targets:
        - name: deps
          kind: prepare
          run: npm ci
        - name: library
          kind: library
          sources: ["lib/**"]
          deps: [":deps"]
      grade:
        - name: library-tests
          run: bin/rspec spec/lib
          when_files_changed:
            - "spec/lib/**"
          deps: [":library"]
    YAML
    stub_changed_files("lib/service.rb")

    handler.call

    grader_step = workflow.steps.find_by!(kind: "grader")
    expect(grader_step.details["prepare_commands"]).to eq([ "npm ci" ])
    expect(grader_step.details["prepare_targets"]).to eq([
      { "target_label" => "//:deps", "commands" => [ "npm ci" ] }
    ])
  end

  it "stores nested prepare dependency project paths for materialized graders" do
    FileUtils.mkdir_p(@ws_path.join("cli"))
    @ws_path.join("cli/.syrus.yml").write(<<~YAML)
      prepare:
        - npm ci
    YAML
    write_config(<<~YAML)
      grade:
        - name: cli-tests
          run: npm test
          deps: ["//cli:prepare"]
    YAML

    handler.call

    grader_step = workflow.steps.find_by!(kind: "grader")
    expect(grader_step.details["prepare_targets"]).to eq([
      { "target_label" => "//cli:prepare", "commands" => [ "npm ci" ], "project_path" => "cli" }
    ])
  end

  it "fails clearly when configured dependency labels are missing" do
    write_config(<<~YAML)
      grade:
        - name: library-tests
          run: bin/rspec spec/lib
          when_files_changed:
            - "spec/lib/**"
          deps: [":missing"]
    YAML
    stub_changed_files("lib/service.rb")

    expect { handler.call }.to raise_error(TargetGraph::ValidationError, /depends on unknown target \/\/:missing/)
  end

  it "logs a message for each skipped grader" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("skipped website-build (no matching files changed)")
  end

  it "logs the target label alongside each skipped grader" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("skipped website-build (no matching files changed) [//:grade/website-build]")
  end

  it "logs each selected grader with its reason and target label" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("selected rspec (repo-wide (no source scope declared)) [//:grade/rspec]")
  end

  it "skips materializing a grader target when target health proves the same inputs already passed" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    health = record_target_health("//:grade/rspec", status: "passed")

    handler.call

    expect(workflow.steps.where(kind: "grader")).to be_empty
    expect(workflow.reload.artifact(Steps::GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY)).to include(
      include(
        "name" => "rspec",
        "target_label" => "//:grade/rspec",
        "target_health_record_id" => health.id,
        "commit_sha" => "previous123"
      )
    )
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("skipped rspec (latest target health record passed from previou) [//:grade/rspec]")
  end

  it "materializes a required grader when the matching target health fingerprint is stale" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    record_target_health("//:grade/rspec", status: "passed", overrides: { input_fingerprint: "stale-input" })

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("target health miss for rspec: target health is unknown [//:grade/rspec]")
  end

  it "materializes a grader when an executable dependency target is stale" do
    write_config(<<~YAML)
      targets:
        - name: deps
          kind: prepare
          run: npm ci
      grade:
        - name: rspec
          run: bin/rspec
          deps: [":deps"]
    YAML
    record_target_health("//:grade/rspec", status: "passed")
    record_target_health("//:deps", status: "passed", overrides: { input_fingerprint: "stale-dependency-input" })

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("target health miss for rspec: dependency //:deps target health is unknown [//:grade/rspec]")
  end

  it "materializes a grader when the latest matching target health record failed" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    record_target_health("//:grade/rspec", status: "passed", checked_at: 2.hours.ago, overrides: { commit_sha: "oldpass" })
    record_target_health("//:grade/rspec", status: "failed", checked_at: 1.hour.ago, overrides: { commit_sha: "newfail" })

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("target health miss for rspec: latest target health is failed [//:grade/rspec]")
  end

  it "materializes a grader when no matching target health record exists" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
    expect(workflow.reload.artifact(Steps::GraderFanout::TARGET_HEALTH_FORCED_ARTIFACT_KEY)).to include(
      include(
        "name" => "rspec",
        "target_label" => "//:grade/rspec",
        "reason" => "target health is unknown",
        "target_fingerprints" => include(
          "input_fingerprint" => match(/\A[0-9a-f]{64}\z/),
          "command_fingerprint" => match(/\A[0-9a-f]{64}\z/),
          "environment_fingerprint" => match(/\A[0-9a-f]{64}\z/)
        )
      )
    )
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("target health miss for rspec: target health is unknown [//:grade/rspec]")
    expect(chunks).to include("forced validation for rspec (target health is unknown) [//:grade/rspec]")
  end

  it "explains a dependency-triggered selection by the dependency's target label" do
    write_config(<<~YAML)
      targets:
        - name: library
          kind: library
          sources: ["lib/**"]
      grade:
        - name: library-tests
          run: bin/rspec spec/lib
          when_files_changed:
            - "spec/lib/**"
          deps: [":library"]
    YAML
    stub_changed_files("lib/service.rb")

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("selected library-tests (dependency //:library source scope matched a changed file) [//:grade/library-tests]")
  end

  it "stores when_files_changed in the materialized Step details" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
            - "docs/**"
    YAML
    stub_changed_files("website/src/index.js")

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["when_files_changed"]).to eq(%w[website/** docs/**])
  end

  it "stores junit_output in the materialized Step details when configured" do
    write_config(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          junit_output: tmp/rspec-results.xml
    YAML

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["junit_output"]).to eq("tmp/rspec-results.xml")
  end

  it "stores nil for junit_output in the materialized Step details when not configured" do
    write_grade_config("bin/rspec")

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["junit_output"]).to be_nil
  end

  it "stores explicit failures policy in the materialized Step details" do
    write_config(<<~YAML)
      grade:
        failures: allow_inherited
        steps:
          - name: tests
            run: bin/rspec
    YAML

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["failures"]).to eq("allow_inherited")
  end

  it "stores strict failures policy by default" do
    write_config(<<~YAML)
      grade:
        - name: react-tests
          run: bin/test-react
          junit_output: .syrus/grade-output/react-tests-junit.xml
    YAML

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["failures"]).to eq("strict")
  end

  it "passes through when all graders have no when_files_changed and changed_files is empty" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files  # no changed files

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
  end

  it "skips conditional graders and logs a warning when the git diff command fails" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    allow(@git).to receive(:run).with("diff", "--name-only", anything, chdir: anything)
      .and_raise(GitRunner::GitError.new([], -1, "no commits yet"))

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec])
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("could not determine changed files")
  end

  it "skips through without materializing any steps when all graders are skipped" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(0)
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("all graders skipped")
  end

  # --- :affected_test_analyzer  ---------------------------------

  describe ":affected_test_analyzer" do
    after { Syrus::PluginRegistry.reset! }

    def register_analyzer(&block)
      analyzer = Class.new do
        define_singleton_method(:affected_files, &block)
      end
      Syrus::PluginRegistry.register(:affected_test_analyzer, analyzer)
      analyzer
    end

    it "is unaffected when no analyzer is registered (regression-safe default)" do
      write_config(<<~YAML)
        grade:
          - name: website-build
            run: npm --prefix website run build
            when_files_changed:
              - "website/**"
          - name: rspec
            run: bin/rspec
      YAML
      stub_changed_files("app/models/user.rb")

      handler.call

      grader_steps = workflow.steps.where(kind: "grader").order(:position)
      expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec])
    end

    it "runs a grader an analyzer reports as transitively affected, which glob-only matching would have skipped" do
      write_config(<<~YAML)
        grade:
          - name: website-build
            run: npm --prefix website run build
            when_files_changed:
              - "website/**"
          - name: rspec
            run: bin/rspec
      YAML
      stub_changed_files("app/models/user.rb")
      register_analyzer { |repo_path:, changed_files:| [ "website/src/generated_from_user.js" ] }

      handler.call

      grader_steps = workflow.steps.where(kind: "grader").order(:position)
      expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[website-build rspec])
    end

    it "does not affect graders whose when_files_changed already matches the raw diff" do
      write_config(<<~YAML)
        grade:
          - name: rspec
            run: bin/rspec
            when_files_changed:
              - "app/**"
      YAML
      stub_changed_files("app/models/user.rb")
      register_analyzer { |repo_path:, changed_files:| [] }

      handler.call

      expect(workflow.steps.where(kind: "grader").count).to eq(1)
    end

    it "falls back to glob-only behavior when the analyzer declines by returning nil" do
      write_config(<<~YAML)
        grade:
          - name: website-build
            run: npm --prefix website run build
            when_files_changed:
              - "website/**"
          - name: rspec
            run: bin/rspec
      YAML
      stub_changed_files("app/models/user.rb")
      register_analyzer { |repo_path:, changed_files:| nil }

      handler.call

      grader_steps = workflow.steps.where(kind: "grader").order(:position)
      expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec])
    end

    it "falls back to glob-only behavior rather than silently skipping a grader when the analyzer raises" do
      write_config(<<~YAML)
        grade:
          - name: website-build
            run: npm --prefix website run build
            when_files_changed:
              - "website/**"
          - name: rspec
            run: bin/rspec
      YAML
      stub_changed_files("website/src/index.js")
      register_analyzer { |repo_path:, changed_files:| raise "boom" }

      handler.call

      grader_steps = workflow.steps.where(kind: "grader").order(:position)
      expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[website-build rspec])
      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("affected_test_analyzer").and include("falling back to glob-only")
    end

    it "does not use analyzer-expanded files for the recorded changed-files fingerprint" do
      write_grade_config("bin/rspec")
      stub_changed_files("app/models/user.rb")
      register_analyzer { |repo_path:, changed_files:| [ "spec/models/user_spec.rb" ] }

      handler.call

      expect(workflow.reload.artifact("grade_plan_changed_files")).to eq([ "app/models/user.rb" ])
    end
  end

  it "persists the HEAD SHA to the workflow artifact" do
    write_grade_config("bin/rspec")

    handler.call

    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY)).to eq("abc123")
  end

  # --- grader-conclusion cache -------------------------------------------

  it "skips materializing graders after a successful conclusion for the same commit and plan" do
    write_grade_config("bin/rspec")
    cached = GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: workflow,
      step: fanout,
      run: run,
      commit_sha: "abc123",
      grader_fingerprint: current_fingerprint,
      grader_name: GraderConclusion::AGGREGATE_NAME,
      required: true,
      status: "passed",
      checked_at: 1.hour.ago
    )

    expect { handler.call }.not_to change { workflow.steps.where(kind: "grader").count }
    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY)).to include(
      "commit_sha" => "abc123",
      "grader_fingerprint" => current_fingerprint,
      "conclusion_id" => cached.id
    )
    expect(fanout.reload.next_step).to eq(collect)
  end

  it "does not reuse failed conclusions for the same commit and plan" do
    write_grade_config("bin/rspec")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: workflow,
      step: fanout,
      run: run,
      commit_sha: "abc123",
      grader_fingerprint: current_fingerprint,
      grader_name: GraderConclusion::AGGREGATE_NAME,
      required: true,
      status: "failed",
      checked_at: 1.hour.ago
    )

    expect { handler.call }.to change { workflow.steps.where(kind: "grader").count }.by(1)
    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY)).to be_nil
    expect(fanout.reload.next_step.kind).to eq("grader")
  end

  it "does not reuse successful conclusions when the grade plan changes" do
    write_grade_config("bin/rspec")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: workflow,
      step: fanout,
      run: run,
      commit_sha: "abc123",
      grader_fingerprint: current_fingerprint,
      grader_name: GraderConclusion::AGGREGATE_NAME,
      required: true,
      status: "passed",
      checked_at: 1.hour.ago
    )
    write_grade_config("bin/rspec spec/models")

    expect { handler.call }.to change { workflow.steps.where(kind: "grader").count }.by(1)
    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY)).to be_nil
  end

  # --- grade.rerun_only_failed ---------------------------------------------

  describe "grade.max_iterations" do
    it "persists a configured max_iterations onto the enclosing retry_until node via Workflow#extend_chain!" do
      workflow.update!(chain_template: [
        { "type" => "retry_until", "max_iterations" => 3, "repair" => [ "implement" ], "check" => %w[grader_fanout grader_collect] }
      ])
      write_config(<<~YAML)
        grade:
          max_iterations: 7
          steps:
            - name: tests
              run: bin/rspec
      YAML

      expect(workflow).to receive(:extend_chain!).and_call_original

      handler.call

      loop_node = workflow.reload.chain_template.find { |node| node["type"] == "retry_until" }
      expect(loop_node["max_iterations"]).to eq(7)
    end

    it "leaves chain_template untouched when no enclosing loop/retry_until node matches this step" do
      workflow.update!(chain_template: [
        { "type" => "retry_until", "max_iterations" => 3, "repair" => [ "implement" ], "check" => %w[some_other_check] }
      ])
      write_config(<<~YAML)
        grade:
          max_iterations: 7
          steps:
            - name: tests
              run: bin/rspec
      YAML

      expect(workflow).not_to receive(:extend_chain!)

      handler.call

      loop_node = workflow.reload.chain_template.find { |node| node["type"] == "retry_until" }
      expect(loop_node["max_iterations"]).to eq(3)
    end
  end

  describe "grade.rerun_only_failed" do
    def create_prior_grader_step(name:, state:, iteration: 1)
      Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 50,
        iteration: iteration,
        loop_id: loop_id,
        state: state,
        details: { "name" => name, "required" => true }
      )
    end

    def build_iteration_two_handler
      collect2 = Step.create!(workflow: workflow, kind: "grader_collect", position: 202, iteration: 2, loop_id: loop_id)
      fanout2 = Step.create!(workflow: workflow, kind: "grader_fanout", position: 201, iteration: 2, loop_id: loop_id, next_step_id: collect2.id)
      run2 = fanout2.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: fanout2.iteration)
      handler2 = described_class.new(run2)
      fake_ws2 = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: "origin/main")
      allow(handler2).to receive(:workspace).and_return(fake_ws2)
      handler2
    end

    it "runs every active grader on the first iteration even when the flag is on" do
      write_config(<<~YAML)
        grade:
          rerun_only_failed: true
          steps:
            - name: tests
              run: bin/rspec
            - name: lint
              run: bin/rubocop
      YAML

      handler.call

      expect(workflow.steps.where(kind: "grader").map { |s| s.details["name"] }).to match_array(%w[tests lint])
    end

    it "reruns every active grader on later iterations when the flag is off (default)" do
      write_config(<<~YAML)
        grade:
          steps:
            - name: tests
              run: bin/rspec
            - name: lint
              run: bin/rubocop
      YAML
      create_prior_grader_step(name: "tests", state: "failed")
      create_prior_grader_step(name: "lint", state: "succeeded")

      build_iteration_two_handler.call

      expect(workflow.steps.where(kind: "grader", iteration: 2).map { |s| s.details["name"] }).to match_array(%w[tests lint])
    end

    it "only reruns graders that failed the previous iteration when the flag is on" do
      write_config(<<~YAML)
        grade:
          rerun_only_failed: true
          steps:
            - name: tests
              run: bin/rspec
            - name: lint
              run: bin/rubocop
      YAML
      create_prior_grader_step(name: "tests", state: "failed")
      create_prior_grader_step(name: "lint", state: "succeeded")

      build_iteration_two_handler.call

      expect(workflow.steps.where(kind: "grader", iteration: 2).map { |s| s.details["name"] }).to eq([ "tests" ])
      carried_forward = workflow.reload.artifact(described_class::CARRIED_FORWARD_ARTIFACT_KEY)
      expect(carried_forward).to contain_exactly(include("name" => "lint", "required" => true))
    end

    it "still runs a grader that newly matches when_files_changed this iteration, even though it wasn't active last iteration" do
      write_config(<<~YAML)
        grade:
          rerun_only_failed: true
          steps:
            - name: tests
              run: bin/rspec
            - name: docs
              run: bin/docs-check
              when_files_changed:
                - "docs/**"
      YAML
      # "docs" never had a Step in iteration 1 (its glob didn't match then) —
      # rerun_only_failed must not treat "no prior Step" as "already passed".
      create_prior_grader_step(name: "tests", state: "failed")

      handler2 = build_iteration_two_handler
      stub_changed_files("docs/readme.md")
      handler2.call

      expect(workflow.steps.where(kind: "grader", iteration: 2).map { |s| s.details["name"] }).to match_array(%w[tests docs])
    end
  end
end
