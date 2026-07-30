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
  end

  it "records the exact GitHub mergeability state and continues when the PR is ready" do
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "clean", mergeable: true, head_sha: "abc", base_sha: "def"))

    described_class.new(run).call

    expect(job.reload.pr_mergeable).to be(true)
    expect(job.github_mergeable).to be(true)
    expect(job.github_mergeable_state).to eq("clean")
    expect(job.mergeability_head_sha).to eq("abc")
    expect(job.mergeability_base_sha).to eq("def")
    expect(run.reload).to be_running
    expect(workflow.reload).to be_running
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
        "base_sha" => "old-base",
        "base_ref" => "main"
      }
    })
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "clean", mergeable: true, head_sha: "abc", base_sha: "def"))

    described_class.new(run).call

    states = workflow.steps.order(:position).pluck(:kind, :state)
    expect(states).to include(
      [ "prepare", "cancelled" ],
      [ "grader_fanout", "cancelled" ],
      [ "grader_collect", "cancelled" ],
      [ "push", "cancelled" ],
      [ "auto_merge", "queued" ]
    )
    expect(workflow.reload).to be_running
    expect(run.reload).to be_running
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
