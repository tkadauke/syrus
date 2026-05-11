require "rails_helper"

RSpec.describe PollAllMergeStatesJob do
  around do |example|
    old = ENV["SYRUS_UNIFIED_MERGE_POLLER"]
    ENV["SYRUS_UNIFIED_MERGE_POLLER"] = "true"
    example.run
  ensure
    ENV["SYRUS_UNIFIED_MERGE_POLLER"] = old
  end

  it "fans out to PollMergeStateJob for open Syrus PRs" do
    syrus_pr = Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")
    no_pr = Factories.job

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollMergeStateJob).with(syrus_pr.id)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(no_pr.id)
  end

  it "is inert until the unified poller flag is enabled" do
    ENV["SYRUS_UNIFIED_MERGE_POLLER"] = "false"
    Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")

    expect { described_class.perform_now }.not_to have_enqueued_job(PollMergeStateJob)
  end
end
