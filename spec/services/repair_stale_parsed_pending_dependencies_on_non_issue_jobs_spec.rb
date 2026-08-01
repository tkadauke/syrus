require "rails_helper"

RSpec.describe Maintenance::RepairStaleParsedPendingDependenciesOnNonIssueJobs do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus") }

  it "removes legacy parsed pending dependencies on direct jobs and starts queued workflows" do
    job = direct_job
    workflow, first_step = queued_workflow_for(job)
    stale = parsed_pending_dependency(job, number: 1101)

    allow(Rails.logger).to receive(:info).and_call_original

    expect {
      result = described_class.call
      expect(result.removed_count).to eq(1)
      expect(result.restarted_job_ids).to eq([ job.id ])
    }.to change { JobDependency.exists?(stale.id) }.from(true).to(false)
      .and change { first_step.runs.count }.by(1)

    expect(Rails.logger).to have_received(:info).with(
      "[JobDependencyRepair] removed stale parsed pending dependency " \
      "job_id=#{job.id} unresolved_ref=tkadauke/syrus#1101"
    )
    expect(workflow.reload).to be_queued
  end

  it "preserves manual pending dependencies on direct jobs" do
    job = direct_job
    manual = JobDependency.create!(
      job: job,
      source: "manual",
      unresolved_owner: repository.owner,
      unresolved_repo: repository.name,
      unresolved_number: 1101
    )

    result = described_class.call

    expect(result.removed_count).to eq(0)
    expect(JobDependency.exists?(manual.id)).to be(true)
  end

  it "resolves manual pending proposal dependencies when the proposal has a Job" do
    job = direct_job
    workflow, first_step = queued_workflow_for(job)
    proposal = proposal_with_job(slug: "materialized-upstream")
    dependency = JobDependency.create!(
      job: job,
      source: "manual",
      unresolved_chat_proposal: proposal
    )

    result = described_class.call

    expect(result.removed_count).to eq(0)
    expect(result.restarted_job_ids).to eq([ job.id ])
    expect(dependency.reload).to be_resolved
    expect(dependency.depends_on_job).to eq(proposal.job)
    expect(first_step.runs.count).to eq(1)
    expect(workflow.reload).to be_queued
  end

  it "removes stale manual pending proposal dependencies and starts queued workflows" do
    job = direct_job
    _workflow, first_step = queued_workflow_for(job)
    stale_proposal = ChatProposal.create!(
      chat_session: ChatSession.create!(user: user, repository: repository),
      slug: "orphaned-upstream",
      title: "Orphaned upstream",
      body: "No longer materializable.",
      state: "withdrawn"
    )
    dependency = JobDependency.create!(
      job: job,
      source: "manual",
      unresolved_chat_proposal: stale_proposal
    )

    expect {
      result = described_class.call
      expect(result.removed_count).to eq(1)
      expect(result.restarted_job_ids).to eq([ job.id ])
    }.to change { JobDependency.exists?(dependency.id) }.from(true).to(false)
      .and change { first_step.runs.count }.by(1)
  end

  it "preserves parsed pending dependencies on issue jobs" do
    job = Factories.job_record(user: user, repository: repository, issue_number: 44, kind: "issue", state: "queued")
    dependency = parsed_pending_dependency(job, number: 1101)

    result = described_class.call

    expect(result.removed_count).to eq(0)
    expect(JobDependency.exists?(dependency.id)).to be(true)
  end

  it "preserves parsed pending dependencies that currently reference Epics" do
    job = direct_job
    epic = Factories.epic(user: user, repository: repository, github_issue_url: "https://github.com/tkadauke/syrus/issues/1101")
    dependency = parsed_pending_dependency(job, number: 1101)

    result = described_class.call

    expect(result.removed_count).to eq(0)
    expect(JobDependency.exists?(dependency.id)).to be(true)
    expect(dependency.reload.referenced_epic).to eq(epic)
  end

  it "is idempotent" do
    job = direct_job
    queued_workflow_for(job)
    parsed_pending_dependency(job, number: 1101)

    first = described_class.call
    second = described_class.call

    expect(first.removed_count).to eq(1)
    expect(second.removed_count).to eq(0)
    expect(second.restarted_job_ids).to eq([])
  end

  it "leaves direct jobs blocked when another real dependency remains" do
    job = direct_job
    _workflow, first_step = queued_workflow_for(job)
    stale = parsed_pending_dependency(job, number: 1101)
    unresolved_manual = JobDependency.create!(
      job: job,
      source: "manual",
      unresolved_owner: repository.owner,
      unresolved_repo: repository.name,
      unresolved_number: 1108
    )

    result = described_class.call

    expect(result.removed_count).to eq(1)
    expect(result.restarted_job_ids).to eq([])
    expect(JobDependency.exists?(stale.id)).to be(false)
    expect(JobDependency.exists?(unresolved_manual.id)).to be(true)
    expect(first_step.runs.count).to eq(0)
  end

  def direct_job
    Factories.job_record(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Direct work",
      issue_body: "Depends-on: #1101",
      state: "queued"
    )
  end

  def queued_workflow_for(job)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    first_step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    [ workflow, first_step ]
  end

  def parsed_pending_dependency(job, number:)
    JobDependency.create!(
      job: job,
      source: "parsed",
      unresolved_owner: repository.owner,
      unresolved_repo: repository.name,
      unresolved_number: number
    )
  end

  def proposal_with_job(slug:)
    upstream = Factories.job_record(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      state: "closed",
      closure_reason: "pr_merged"
    )
    ChatProposal.create!(
      chat_session: ChatSession.create!(user: user, repository: repository),
      slug: slug,
      title: "Materialized upstream",
      body: "Already filed.",
      state: "confirmed",
      job: upstream
    )
  end
end
