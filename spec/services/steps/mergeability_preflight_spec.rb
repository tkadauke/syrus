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

  def pr(state: "open", mergeable_state: "clean", mergeable: true, head_sha: "head", base_ref: "main", base_sha: "base")
    OpenStruct.new(
      state: state,
      mergeable: mergeable,
      mergeable_state: mergeable_state,
      labels: [],
      head: OpenStruct.new(sha: head_sha),
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

  it "defers before prepare when GitHub mergeability is unknown and local rebase is clean" do
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
    }.to have_enqueued_job(LandingQueueProcessorJob)
      .at(be_within(1.second).of(LandingQueueProcessor::MERGEABILITY_RECHECK_DELAY.from_now))

    expect(job.reload).to be_approved
    expect(job.github_mergeable).to be_nil
    expect(job.github_mergeable_state).to eq("unknown")
    expect(job.local_mergeable).to be(true)
    expect(job.local_mergeable_state).to eq("clean")
    expect(run.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
    expect(workflow.steps.where(kind: "prepare").first).to be_cancelled
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
end
