require "rails_helper"

RSpec.describe MergeLock do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }

  def landing_unit(started_at:, pr_number:)
    job = Factories.job(user: user, repository: repository, pr_number: pr_number, branch_name: "syrus/issue-#{pr_number}-1")
    workflow = Workflows::AutoMerge.instantiate(job: job)
    unit = attach_work_unit(workflow, state: "running")
    unit.update!(started_at: started_at)
    workflow.steps.last.update_columns(state: "running")
    [ workflow, job, unit ]
  end

  it "derives a merge key mirroring the landing key" do
    job = Factories.job(user: user, repository: repository)
    expect(WorkDefinitions.merge_lock_key_for(job)).to eq("merge:repository:#{repository.id}")
    allow(WorkDefinitions).to receive(:landing_lock_key_for).and_return("landing:repository:#{repository.id}:branch:hotfix")
    expect(WorkDefinitions.merge_lock_key_for(job)).to eq("merge:repository:#{repository.id}:branch:hotfix")
  end

  it "grants an uncontended lock and releases it" do
    workflow, job, unit = landing_unit(started_at: 1.hour.ago, pr_number: 1)
    lease = described_class.try_acquire(workflow: workflow, job: job)
    expect(unit.work_unit_locks.active.pluck(:lock_key)).to include("merge:repository:#{repository.id}")
    lease.release!
    expect(unit.work_unit_locks.active.pluck(:lock_key)).not_to include("merge:repository:#{repository.id}")
  end

  it "refuses a second holder until the first releases" do
    wf1, job1, = landing_unit(started_at: 2.hours.ago, pr_number: 1)
    wf2, job2, = landing_unit(started_at: 1.hour.ago, pr_number: 2)
    lease = described_class.try_acquire(workflow: wf1, job: job1)
    expect(described_class.try_acquire(workflow: wf2, job: job2)).to be_nil
    lease.release!
    wf1.steps.last.update_columns(state: "succeeded")
    expect(described_class.try_acquire(workflow: wf2, job: job2)).to be_present
  end

  it "hands the free lock to the earliest-started waiter (FIFO)" do
    early_wf, early_job, = landing_unit(started_at: 3.hours.ago, pr_number: 1)
    late_wf, late_job, = landing_unit(started_at: 1.hour.ago, pr_number: 2)
    expect(described_class.try_acquire(workflow: late_wf, job: late_job)).to be_nil
    expect(described_class.try_acquire(workflow: early_wf, job: early_job)).to be_present
  end

  it "is released by the terminal work unit machinery when the holder is gone" do
    wf, job, unit = landing_unit(started_at: 1.hour.ago, pr_number: 1)
    described_class.try_acquire(workflow: wf, job: job)
    unit.mark_terminal!("failed")
    expect(unit.work_unit_locks.active).to be_empty
  end
end
