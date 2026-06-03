require "rails_helper"

RSpec.describe LandingQueueProcessor do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def queue_job(issue_number:, approved_at:, parent_job: nil, pr_number: issue_number, repository: self.repository, epic: nil)
    # Start in :implemented so approve! works directly; mirrors the
    # production flow where mark_implemented! happens before approval
    # (post audit, :open → :implemented → :approved is the only
    # legal pre-approval chain).
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: issue_number,
      pr_number: pr_number,
      parent_job: parent_job,
      epic: epic,
      state: "implemented"
    ).tap do |job|
      job.approve!(via: "github_review")
      job.update!(approved_at: approved_at)
    end
  end

  it "lands an approved stack parent before its child" do
    child = queue_job(issue_number: 2, approved_at: 2.minutes.ago)
    parent = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    child.update!(parent_job: parent)

    workflow = described_class.call

    expect(workflow.job).to eq(parent)
    expect(parent.reload).to be_landing
    expect(child.reload).to be_approved
  end

  it "keeps dependency-blocked Jobs approved and lands the next eligible Job" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 1, state: "queued", pr_number: 1)
    blocked = queue_job(issue_number: 2, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 3, approved_at: 1.minute.ago)
    JobDependency.create!(job: blocked, depends_on_job: prerequisite, source: "manual")

    workflow = described_class.call

    expect(workflow.job).to eq(ready)
    expect(blocked.reload).to be_approved
    entry = described_class.entries(Job.where(id: blocked.id)).first
    expect(entry.blocked_reason).to include("waiting for #1 to merge")
  end

  it "does not process paused users but resumes when unpaused" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    user.update!(landing_paused: true)

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved

    user.update!(landing_paused: false)
    expect(described_class.call.job).to eq(job)
  end

  it "blocks approved Jobs after a no-op rebase while GitHub still reports unmergeable" do
    job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
    job.update!(pr_mergeable: false)
    Workflows::Rebase.instantiate(job: job).update!(
      state: "succeeded",
      artifacts: {
        "auto_rebase_result" => {
          "reason" => "rebased",
          "changed" => false,
          "post_sha" => "abc",
          "base_sha" => "base"
        }
      }
    )

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved
    entry = described_class.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to eq(RebaseLoopGuard::BLOCK_REASON)
  end

  it "holds approved epic jobs until every open sibling is approved" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    approved = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 2,
      pr_number: 2,
      state: "implemented"
    )

    expect(described_class.call).to be_nil
    expect(approved.reload).to be_approved
    entry = described_class.entries(Job.where(id: approved.id)).first
    expect(entry.blocked_reason).to eq("waiting for epic siblings to be approved")
  end

  it "ignores closed epic siblings when checking whether every open sibling is approved" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    approved = queue_job(issue_number: 1, approved_at: 1.minute.ago, epic: epic)
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 2,
      pr_number: 2,
      state: "closed",
      closure_reason: "pr_merged"
    )

    workflow = described_class.call

    expect(workflow.job).to eq(approved)
    expect(approved.reload).to be_landing
  end

  it "lands approved Jobs in different repositories in the same tick" do
    other_repository = Factories.repository(user: user, auto_merge_enabled: true, name: "other")
    first = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    second = queue_job(issue_number: 2, approved_at: 1.minute.ago, repository: other_repository)

    workflow = described_class.call

    expect(workflow.job).to eq(first)
    expect(first.reload).to be_landing
    expect(second.reload).to be_landing
    expect(Workflow.where(trigger_kind: "auto_merge").pluck(:job_id)).to contain_exactly(first.id, second.id)
  end

  it "lands only the oldest approved Job per repository in the same tick" do
    older = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    newer = queue_job(issue_number: 2, approved_at: 1.minute.ago)

    workflow = described_class.call

    expect(workflow.job).to eq(older)
    expect(older.reload).to be_landing
    expect(newer.reload).to be_approved
  end

  it "lands an approved Job from another repository while a repository is already landing" do
    other_repository = Factories.repository(user: user, auto_merge_enabled: true, name: "other")
    landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago, repository: other_repository)
    landing.start_landing!
    landing.save!

    workflow = described_class.call

    expect(workflow.job).to eq(ready)
    expect(ready.reload).to be_landing
  end

  it "skips an approved Job whose repository is already landing" do
    landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    landing.start_landing!
    landing.save!

    expect(described_class.call).to be_nil
    expect(ready.reload).to be_approved
  end

  # Regression: an approved Job on a repo without auto_merge_enabled
  # used to be picked up by the queue, transitioned to :landing,
  # then immediately failed at AutoMergeGate ("repository has not
  # enabled auto-merge") — which fail_landing'd and wiped the
  # approved_at. blockage_for now catches this so the Job stays
  # approved with a clear blocked_reason until the repo is configured.
  it "blocks approved Jobs whose repository does not have auto-merge enabled" do
    disabled_repo = Factories.repository(user: user, auto_merge_enabled: false)
    job = Factories.job_record(user: user, repository: disabled_repo, issue_number: 1,
                                pr_number: 1, state: "implemented").tap do |j|
      j.approve!(via: "github_review")
    end

    expect(described_class.call).to be_nil
    expect(job.reload).to be_approved
    entry = described_class.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to include("auto-merge not enabled")
  end

  describe ".try_land!" do
    it "enqueues an immediate landing-queue pass when no specific Job is given" do
      expect {
        described_class.try_land!
      }.to have_enqueued_job(LandingQueueProcessorJob)
    end

    it "dispatches an AutoMerge workflow for a specific approved Job" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)

      workflow = described_class.try_land!(job)

      expect(workflow).to be_present
      expect(workflow.trigger_kind).to eq("auto_merge")
      expect(job.reload).to be_landing
    end

    it "no-ops when the Job is not approved" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "implemented")

      expect(described_class.try_land!(job)).to be_nil
      expect(job.reload).to be_implemented
    end

    it "no-ops when a blocker (active workflow) is present" do
      job = queue_job(issue_number: 1, approved_at: 1.minute.ago)
      Workflows::Rebase.instantiate(job: job).update!(state: "running")

      expect(described_class.try_land!(job)).to be_nil
      expect(job.reload).to be_approved
    end

    it "no-ops when another Job in the same repository is already landing" do
      already_landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
      already_landing.start_landing!
      already_landing.save!

      target = queue_job(issue_number: 2, approved_at: 1.minute.ago)

      expect(described_class.try_land!(target)).to be_nil
      expect(target.reload).to be_approved
    end

    it "dispatches when another repository is already landing" do
      other_repository = Factories.repository(user: user, auto_merge_enabled: true, name: "other")
      already_landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
      already_landing.start_landing!
      already_landing.save!

      target = queue_job(issue_number: 2, approved_at: 1.minute.ago, repository: other_repository)

      workflow = described_class.try_land!(target)

      expect(workflow.job).to eq(target)
      expect(target.reload).to be_landing
    end
  end
end
