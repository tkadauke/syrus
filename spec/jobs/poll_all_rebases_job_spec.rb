require "rails_helper"

RSpec.describe PollAllRebasesJob do
  around do |example|
    old = ENV["SYRUS_UNIFIED_MERGE_POLLER"]
    ENV["SYRUS_UNIFIED_MERGE_POLLER"] = nil
    example.run
  ensure
    ENV["SYRUS_UNIFIED_MERGE_POLLER"] = old
  end

  it "fans out to PollRebaseJob for every Job with a PR (Syrus or external), regardless of state" do
    syrus_pr   = Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")
    external   = Factories.job
    external.update!(state: "closed", closure_reason: "preempted",
                     external_pr_number: 99, finished_at: Time.current)
    closed_syr = Factories.job(pr_number: 8, branch_name: "syrus/issue-2-2")
    closed_syr.close_with_reason!("manual")
    no_pr      = Factories.job

    # No-PR Job is excluded (the SQL filter in PollAllRebasesJob).
    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollRebaseJob).exactly(3).times
      .and have_enqueued_job(PollRebaseJob).with(syrus_pr.id)
      .and have_enqueued_job(PollRebaseJob).with(external.id)
      .and have_enqueued_job(PollRebaseJob).with(closed_syr.id)
    expect(no_pr.pr_number).to be_nil  # sanity
  end

  it "skips Jobs whose Repository is archived" do
    archived_repo = Factories.repository
    archived_repo.archive!
    archived_job = Factories.job(repository: archived_repo, pr_number: 11, branch_name: "syrus/x")
    active_job   = Factories.job(pr_number: 12, branch_name: "syrus/y")

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollRebaseJob).exactly(1).times
      .and have_enqueued_job(PollRebaseJob).with(active_job.id)
    expect {
      # Sanity: the archived Job did NOT get enqueued.
      described_class.perform_now
    }.not_to have_enqueued_job(PollRebaseJob).with(archived_job.id)
  end

  it "is inert when the unified merge poller is enabled" do
    ENV["SYRUS_UNIFIED_MERGE_POLLER"] = "true"
    Factories.job(pr_number: 7, branch_name: "syrus/x")

    expect { described_class.perform_now }.not_to have_enqueued_job(PollRebaseJob)
  end
end
