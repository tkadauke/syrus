require "rails_helper"
require "ostruct"

RSpec.describe Steps::MergeabilityPreflight do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1") }
  let(:workflow) { Workflows::AutoMerge.instantiate(job: job) }
  let(:step) { workflow.steps.first }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "auto_merge") }
  let(:client) { instance_double(GithubClient) }
  let(:no_op_rebase_result) do
    AutoRebase::Result.new(
      true,
      "rebased",
      "no-op (already up-to-date)",
      changed: false,
      pre_sha: "head",
      post_sha: "head",
      base_sha: "base"
    )
  end

  def pr(state: "open", mergeable_state: "clean", mergeable: true, head_sha: "head", head_ref: "feature", head_repo: "acme/widgets", base_ref: "main", base_sha: "base")
    OpenStruct.new(
      state: state,
      mergeable: mergeable,
      mergeable_state: mergeable_state,
      labels: [],
      head: OpenStruct.new(sha: head_sha, ref: head_ref, repo: OpenStruct.new(full_name: head_repo)),
      base: OpenStruct.new(ref: base_ref, sha: base_sha)
    )
  end

  def start_landing!
    job.mark_implemented! if job.may_mark_implemented?
    job.save!
    job.approve!(via: "operator")
    job.start_landing!
    job.save!
    workflow.start!
    workflow.save!
    step.start!
    step.save!
    run.start!
    run.save!
  end

  before do
    start_landing!
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:pr_reviews).and_return([])
    allow(client).to receive(:pr_issue_comments).and_return([])
    allow(client).to receive(:pr_commits).and_return([])
    allow(client).to receive(:branch_head_sha).and_return("base")
    allow(AutoRebase).to receive(:new).and_return(instance_double(AutoRebase, call: no_op_rebase_result))
  end

  it "records the exact GitHub mergeability state and continues when the PR is ready" do
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "clean", mergeable: true, head_sha: "abc", base_sha: "def"))

    described_class.new(run).call

    expect(job.reload.pr_mergeable).to be(true)
    expect(job.github_mergeable).to be(true)
    expect(job.github_mergeable_state).to eq("clean")
    expect(job.mergeability_head_sha).to eq("abc")
    expect(job.mergeability_base_sha).to eq("def")
    expect(job.local_mergeable).to be(true)
    expect(job.local_mergeable_state).to eq("clean")
    expect(run.reload).to be_running
    expect(workflow.reload).to be_running
  end

  it "mechanically rebases and pushes the PR branch before landing graders" do
    rebase_result = AutoRebase::Result.new(
      true,
      "rebased",
      "advanced abc1234 to fedcba9",
      changed: true,
      pre_sha: "abc1234",
      post_sha: "fedcba9",
      base_sha: "def5678"
    )
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "clean", mergeable: true, head_sha: "abc1234", base_sha: "def5678"))
    allow(AutoRebase).to receive(:new).with(job, base_branch: "main").and_return(instance_double(AutoRebase, call: rebase_result))

    described_class.new(run).call

    expect(job.reload.mergeability_head_sha).to eq("fedcba9")
    expect(job.mergeability_base_sha).to eq("def5678")
    expect(job.local_mergeable).to be(true)
    expect(job.local_mergeability_head_sha).to eq("fedcba9")
    expect(workflow.artifact("mergeability_preflight_rebase")).to include(
      "succeeded" => true,
      "changed" => true,
      "post_sha" => "fedcba9",
      "base_sha" => "def5678"
    )
    expect(workflow.artifact(LandingThroughputMetrics::ARTIFACT_KEY).dig("validation_decisions").last).to include(
      "context" => "auto_merge",
      "head_sha" => "fedcba9",
      "base_sha" => "def5678"
    )
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("auto_merge: mechanically rebased and pushed syrus/issue-42-1 before landing graders")
    expect(run.reload).to be_running
    expect(workflow.reload).to be_running
  end

  it "dispatches a rebase workflow when the mechanical rebase conflicts before landing graders" do
    rebase_result = AutoRebase::Result.new(
      false,
      "conflict",
      nil,
      pre_sha: "abc1234",
      base_sha: "def5678"
    )
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "clean", mergeable: true, head_sha: "abc1234", base_sha: "def5678"))
    allow(AutoRebase).to receive(:new).with(job, base_branch: "main").and_return(instance_double(AutoRebase, call: rebase_result))
    allow(StepDispatcher).to receive(:start_workflow)

    expect {
      described_class.new(run).call
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    expect(job.reload).to be_approved
    expect(run.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("mergeability_preflight_rebase")).to include(
      "succeeded" => false,
      "reason" => "conflict",
      "pre_sha" => "abc1234",
      "base_sha" => "def5678"
    )
    expect(StepDispatcher).to have_received(:start_workflow).with(an_instance_of(Workflow))
  end

  it "continues to prepare when GitHub mergeability is unknown and local rebase is clean" do
    local_result = LocalMergeabilityCheck::Result.new(
      state: "clean",
      mergeable: true,
      message: "local rebase preflight passed",
      head_sha: "abc",
      base_sha: "def",
      base_ref: "main"
    )
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "unknown", mergeable: nil, head_sha: "abc", base_sha: "def"))
    allow(LocalMergeabilityCheck).to receive(:new).and_return(instance_double(LocalMergeabilityCheck, call: local_result))

    expect {
      described_class.new(run).call
    }.not_to have_enqueued_job(LandingQueueProcessorJob)

    expect(job.reload).to be_landing
    expect(job.github_mergeable).to be_nil
    expect(job.github_mergeable_state).to eq("unknown")
    expect(job.local_mergeable).to be(true)
    expect(job.local_mergeable_state).to eq("clean")
    expect(run.reload).to be_running
    expect(step.reload).to be_running
    expect(workflow.reload).to be_running
    expect(workflow.steps.where(kind: "prepare").first).to be_queued
    expect(run.job_logs.pluck(:chunk)).to include(include("auto_merge: continuing - mergeable_state=unknown; local rebase preflight passed"))
  end

  it "dispatches a rebase before prepare when GitHub is unknown but the local check finds conflicts" do
    local_result = LocalMergeabilityCheck::Result.new(
      state: "conflict",
      mergeable: false,
      message: "local rebase preflight found conflicts",
      head_sha: "abc",
      base_sha: "def",
      base_ref: "main"
    )
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "unknown", mergeable: nil, head_sha: "abc", base_sha: "def"))
    allow(LocalMergeabilityCheck).to receive(:new).and_return(instance_double(LocalMergeabilityCheck, call: local_result))
    allow(StepDispatcher).to receive(:start_workflow)

    expect {
      described_class.new(run).call
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    expect(job.reload).to be_approved
    expect(job.local_mergeable).to be(false)
    expect(job.local_mergeable_state).to eq("conflict")
    expect(run.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
    expect(StepDispatcher).to have_received(:start_workflow).with(an_instance_of(Workflow))
  end

  it "defers before prepare when GitHub mergeability is unknown and local rebase is inconclusive" do
    local_result = LocalMergeabilityCheck::Result.new(
      state: "error",
      mergeable: nil,
      message: "GitRunner::Error: fetch failed",
      head_sha: "abc",
      base_sha: "def",
      base_ref: "main"
    )
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "unknown", mergeable: nil, head_sha: "abc", base_sha: "def"))
    allow(LocalMergeabilityCheck).to receive(:new).and_return(instance_double(LocalMergeabilityCheck, call: local_result))

    expect {
      described_class.new(run).call
    }.to have_enqueued_job(LandingQueueProcessorJob)
      .at(be_within(3.seconds).of(LandingQueueProcessor::MERGEABILITY_RECHECK_DELAY.from_now))

    expect(job.reload).to be_approved
    expect(job.github_mergeable).to be_nil
    expect(job.github_mergeable_state).to eq("unknown")
    expect(job.local_mergeable).to be_nil
    expect(job.local_mergeable_state).to eq("error")
    expect(run.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
    expect(workflow.steps.where(kind: "prepare").first).to be_cancelled
  end

  it "skips prepare, graders, and push when the same head already passed grading" do
    prior = Workflows::Initial.instantiate(job: job)
    prior.update!(artifacts: {
      LandingValidationCache::ARTIFACT_KEY => {
        "required_graders_passed" => true,
        "head_sha" => "abc",
        "tree_sha" => "tree-abc",
        "base_sha" => "def",
        "base_ref" => "main",
        "grader_fingerprint" => "fp",
        "changed_files_fingerprint" => LandingValidationCache.changed_files_fingerprint([ "app/models/job.rb" ])
      }
    })
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "clean", mergeable: true, head_sha: "abc", base_sha: "def"))
    allow(client).to receive(:commit_tree_sha).with("acme/widgets", "abc").and_return("tree-abc")
    allow(client).to receive(:commit_tree_sha).with("acme/widgets", "def").and_return("tree-def")
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace, setup: nil, path: Rails.root)
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(GraderConclusionCache).to receive(:fingerprint_for_plan).and_return("fp")
    allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner, run: "app/models/job.rb\n"))

    handler.call

    states = workflow.steps.order(:position).pluck(:kind, :state)
    expect(states).to include(
      [ "prepare", "skipped" ],
      [ "grader_fanout", "skipped" ],
      [ "grader_collect", "skipped" ],
      [ "push", "skipped" ],
      [ "auto_merge", "queued" ]
    )
    expect(workflow.reload).to be_running
    expect(run.reload).to be_running
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("auto_merge: reusing cached landing validation (exact_head)")
    expect(workflow.artifact(LandingThroughputMetrics::ARTIFACT_KEY).dig("validation_decisions").last).to include(
      "context" => "auto_merge",
      "outcome" => "skipped",
      "match_type" => "exact_head",
      "reason" => "head/base/grader configuration match",
      "head_sha" => "abc",
      "base_sha" => "def",
      "source_workflow_id" => prior.id
    )
  end

  it "runs landing graders when the cached validation has a different base" do
    prior = Workflows::Initial.instantiate(job: job)
    prior.update!(artifacts: {
      LandingValidationCache::ARTIFACT_KEY => {
        "required_graders_passed" => true,
        "head_sha" => "abc",
        "tree_sha" => "tree-abc",
        "base_sha" => "old-base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp",
        "changed_files_fingerprint" => LandingValidationCache.changed_files_fingerprint([ "app/models/job.rb" ])
      }
    })
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "clean", mergeable: true, head_sha: "abc", base_sha: "new-base"))
    allow(client).to receive(:commit_tree_sha).with("acme/widgets", "abc").and_return("tree-abc")
    allow(client).to receive(:commit_tree_sha).with("acme/widgets", "new-base").and_return("new-base-tree")
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace, setup: nil, path: Rails.root)
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(GraderConclusionCache).to receive(:fingerprint_for_plan).and_return("fp")
    allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner, run: "app/models/job.rb\n"))

    handler.call

    expect(workflow.steps.find_by!(kind: "grader_fanout")).to be_queued
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("auto_merge: landing graders will run - base SHA changed")
    expect(workflow.reload.artifact(LandingThroughputMetrics::ARTIFACT_KEY).dig("validation_decisions").last).to include(
      "context" => "auto_merge",
      "outcome" => "rerun",
      "reason" => include("base SHA changed"),
      "head_sha" => "abc",
      "base_sha" => "new-base"
    )
  end

  context "with an external_pr job" do
    # external_pr Jobs must be created in :implemented state (validated on create).
    # Factories.job_record always overrides state to "closed" then update_columns,
    # so we use Job.create! directly for external_pr kind.
    let(:external_pr_job) do
      Job.create!(
        user: user,
        owner_user: user,
        repository: repository,
        kind: "external_pr",
        issue_number: nil,
        external_pr_number: 99,
        state: "implemented"
      )
    end
    let(:external_workflow) { Workflows::ExternalPrMerge.instantiate(job: external_pr_job) }
    let(:external_step) { external_workflow.steps.first }
    let(:external_run) { Run.create!(job: external_pr_job, step: external_step, trigger_kind: "external_pr_merge") }

    before do
      external_pr_job.approve!(via: "operator")
      external_pr_job.start_landing!
      external_pr_job.save!
      external_workflow.start!
      external_workflow.save!
      external_step.start!
      external_step.save!
      external_run.start!
      external_run.save!
    end

    it "proceeds when the external PR is open and mergeable" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "clean", head_sha: "abc123", head_ref: "feature-branch", head_repo: "acme/widgets")
      )

      described_class.new(external_run).call

      expect(external_run.reload).to be_running
      expect(external_workflow.reload).to be_running
      expect(external_workflow.artifact("external_pr_head_repo")).to eq("acme/widgets")
      expect(external_workflow.artifact("external_pr_head_ref")).to eq("feature-branch")
      expect(external_workflow.artifact("external_pr_head_sha")).to eq("abc123")
    end

    it "mechanically rebases same-repository external PRs before landing graders" do
      rebase_result = AutoRebase::Result.new(
        true,
        "rebased",
        "advanced abc1234 to def5678",
        changed: true,
        pre_sha: "abc1234",
        post_sha: "def5678",
        base_sha: "base999"
      )
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "clean", head_sha: "abc1234", head_ref: "contributor-branch", head_repo: "acme/widgets", base_sha: "base999")
      )
      allow(AutoRebase).to receive(:new)
        .with(external_pr_job, base_branch: "main", branch_name: "contributor-branch")
        .and_return(instance_double(AutoRebase, call: rebase_result))

      described_class.new(external_run).call

      expect(external_pr_job.reload.mergeability_head_sha).to eq("def5678")
      expect(external_pr_job.local_mergeability_head_sha).to eq("def5678")
      expect(external_workflow.artifact("external_pr_head_sha")).to eq("def5678")
      expect(external_workflow.artifact("mergeability_preflight_rebase")).to include(
        "succeeded" => true,
        "changed" => true,
        "pre_sha" => "abc1234",
        "post_sha" => "def5678",
        "base_sha" => "base999"
      )
      expect(external_run.job_logs.pluck(:chunk).join("\n")).to include("external_pr_merge: mechanically rebased and pushed contributor-branch before landing graders")
      expect(external_run.reload).to be_running
      expect(external_workflow.reload).to be_running
    end

    it "dispatches a rebase workflow for same-repository external PR conflicts before landing graders" do
      rebase_result = AutoRebase::Result.new(
        false,
        "conflict",
        nil,
        pre_sha: "abc1234",
        base_sha: "base999"
      )
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "clean", head_sha: "abc1234", head_ref: "contributor-branch", head_repo: "acme/widgets", base_sha: "base999")
      )
      allow(AutoRebase).to receive(:new)
        .with(external_pr_job, base_branch: "main", branch_name: "contributor-branch")
        .and_return(instance_double(AutoRebase, call: rebase_result))
      allow(StepDispatcher).to receive(:start_workflow)

      expect {
        described_class.new(external_run).call
      }.to change { external_pr_job.workflows.where(trigger_kind: "rebase").count }.by(1)

      rebase_workflow = external_pr_job.workflows.where(trigger_kind: "rebase").last
      expect(rebase_workflow.artifact(RebaseTarget::BRANCH_ARTIFACT)).to eq("contributor-branch")
      expect(rebase_workflow.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT)).to eq("main")
      expect(external_pr_job.reload).to be_approved
      expect(external_run.reload).to be_cancelled
      expect(external_workflow.reload).to be_cancelled
      expect(StepDispatcher).to have_received(:start_workflow).with(rebase_workflow)
    end

    it "does not mechanically rebase fork external PRs" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "clean", head_sha: "abc123", head_ref: "contributor-branch", head_repo: "fork/widgets")
      )
      expect(AutoRebase).not_to receive(:new)

      described_class.new(external_run).call

      expect(external_run.reload).to be_running
      expect(external_workflow.reload).to be_running
      expect(external_workflow.artifact("external_pr_head_sha")).to eq("abc123")
    end

    it "proceeds when GitHub reports unstable (non-required check failing)" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "unstable")
      )

      described_class.new(external_run).call

      expect(external_run.reload).to be_running
    end

    it "cancels the workflow and closes the job as merged when the external PR is already merged" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        OpenStruct.new(state: "closed", merged: true, mergeable_state: nil,
                       head: OpenStruct.new(sha: "abc"), base: OpenStruct.new(ref: "main", sha: "base"))
      )

      described_class.new(external_run).call

      expect(external_workflow.reload).to be_cancelled
      expect(external_pr_job.reload).to be_closed
      expect(external_pr_job.closure_reason).to eq("external_pr_merged")
    end

    it "cancels the workflow and closes the job when the external PR was closed without merging" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        OpenStruct.new(state: "closed", merged: false, mergeable_state: nil,
                       head: OpenStruct.new(sha: "abc"), base: OpenStruct.new(ref: "main", sha: "base"))
      )

      described_class.new(external_run).call

      expect(external_workflow.reload).to be_cancelled
      expect(external_pr_job.reload).to be_closed
      expect(external_pr_job.closure_reason).to eq("external_pr_closed")
    end

    it "defers and enqueues a mergeability recheck when GitHub is still computing" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "unknown")
      )

      expect {
        described_class.new(external_run).call
      }.to have_enqueued_job(LandingQueueProcessorJob)
        .at(be_within(3.seconds).of(LandingQueueProcessor::MERGEABILITY_RECHECK_DELAY.from_now))

      expect(external_pr_job.reload).to be_approved
      expect(external_workflow.reload).to be_cancelled
    end

    it "raises StepFailed when the external PR is not mergeable (e.g. blocked)" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "blocked")
      )

      expect {
        described_class.new(external_run).call
      }.to raise_error(Steps::Base::StepFailed, /not mergeable.*blocked/)
    end
  end

  context "with an external_pr job" do
    # external_pr Jobs must be created in :implemented state (validated on create).
    # Factories.job_record always overrides state to "closed" then update_columns,
    # so we use Job.create! directly for external_pr kind.
    let(:external_pr_job) do
      Job.create!(
        user: user,
        owner_user: user,
        repository: repository,
        kind: "external_pr",
        issue_number: nil,
        external_pr_number: 99,
        state: "implemented"
      )
    end
    let(:external_workflow) { Workflows::ExternalPrMerge.instantiate(job: external_pr_job) }
    let(:external_step) { external_workflow.steps.first }
    let(:external_run) { Run.create!(job: external_pr_job, step: external_step, trigger_kind: "external_pr_merge") }

    before do
      external_pr_job.approve!(via: "operator")
      external_pr_job.start_landing!
      external_pr_job.save!
      external_workflow.start!
      external_workflow.save!
      external_step.start!
      external_step.save!
      external_run.start!
      external_run.save!
    end

    it "proceeds when the external PR is open and mergeable" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "clean", head_sha: "abc123", head_ref: "feature-branch", head_repo: "acme/widgets")
      )

      described_class.new(external_run).call

      expect(external_run.reload).to be_running
      expect(external_workflow.reload).to be_running
      expect(external_workflow.artifact("external_pr_head_repo")).to eq("acme/widgets")
      expect(external_workflow.artifact("external_pr_head_ref")).to eq("feature-branch")
      expect(external_workflow.artifact("external_pr_head_sha")).to eq("abc123")
    end

    it "proceeds when GitHub reports unstable (non-required check failing)" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "unstable")
      )

      described_class.new(external_run).call

      expect(external_run.reload).to be_running
    end

    it "cancels the workflow and closes the job as merged when the external PR is already merged" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        OpenStruct.new(state: "closed", merged: true, mergeable_state: nil,
                       head: OpenStruct.new(sha: "abc"), base: OpenStruct.new(ref: "main", sha: "base"))
      )

      described_class.new(external_run).call

      expect(external_workflow.reload).to be_cancelled
      expect(external_pr_job.reload).to be_closed
      expect(external_pr_job.closure_reason).to eq("external_pr_merged")
    end

    it "cancels the workflow and closes the job when the external PR was closed without merging" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        OpenStruct.new(state: "closed", merged: false, mergeable_state: nil,
                       head: OpenStruct.new(sha: "abc"), base: OpenStruct.new(ref: "main", sha: "base"))
      )

      described_class.new(external_run).call

      expect(external_workflow.reload).to be_cancelled
      expect(external_pr_job.reload).to be_closed
      expect(external_pr_job.closure_reason).to eq("external_pr_closed")
    end

    it "defers and enqueues a mergeability recheck when GitHub is still computing" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "unknown")
      )

      expect {
        described_class.new(external_run).call
      }.to have_enqueued_job(LandingQueueProcessorJob)
        .at(be_within(3.seconds).of(LandingQueueProcessor::MERGEABILITY_RECHECK_DELAY.from_now))

      expect(external_pr_job.reload).to be_approved
      expect(external_workflow.reload).to be_cancelled
    end

    it "raises StepFailed when the external PR is not mergeable (e.g. blocked)" do
      allow(client).to receive(:pull_request).with("acme/widgets", 99, anything).and_return(
        pr(state: "open", mergeable_state: "blocked")
      )

      expect {
        described_class.new(external_run).call
      }.to raise_error(Steps::Base::StepFailed, /not mergeable.*blocked/)
    end
  end
end
