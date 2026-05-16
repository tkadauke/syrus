require "rails_helper"

RSpec.describe LandingQueueProcessor do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def queue_job(issue_number:, approved_at:, parent_job: nil, pr_number: issue_number)
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: issue_number,
      pr_number: pr_number,
      parent_job: parent_job,
      state: "open"
    ).tap do |job|
      job.approve!
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
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 1, state: "open", pr_number: 1)
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

  it "waits while any Job is already landing" do
    landing = queue_job(issue_number: 1, approved_at: 2.minutes.ago)
    ready = queue_job(issue_number: 2, approved_at: 1.minute.ago)
    landing.start_landing!
    landing.save!

    expect(described_class.call).to be_nil
    expect(ready.reload).to be_approved
  end
end
