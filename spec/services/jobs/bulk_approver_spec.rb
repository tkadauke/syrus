require "rails_helper"

RSpec.describe Jobs::BulkApprover do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def implemented_job(issue_number:)
    Factories.job_record(user: user, repository: repository, issue_number: issue_number, state: "implemented")
  end

  it "approves every eligible job and stamps approval metadata" do
    first = implemented_job(issue_number: 1)
    second = implemented_job(issue_number: 2)

    result = described_class.call([ first, second ], via: "bulk", by_user: user, evidence: { "batch_id" => "abc" })

    expect(result).to be_success
    expect(result.approved).to contain_exactly(first, second)
    expect(result.failed).to be_empty
    expect(first.reload).to be_approved
    expect(first.approved_via).to eq("bulk")
    expect(first.approved_by_user).to eq(user)
    expect(first.approval_evidence).to eq({ "batch_id" => "abc" })
    expect(second.reload).to be_approved
  end

  it "excludes a job that becomes ineligible for approval between the caller's filter and the row lock" do
    stale = implemented_job(issue_number: 1)
    fresh = implemented_job(issue_number: 2)

    # Simulate a concurrent transition (e.g. the PR poller's auto-approval,
    # or AutoApprovalRule) landing on `stale` in the window between the
    # caller's initial `may_approve?` filter and the service's row lock.
    # `lock!` is where the service re-observes the row, so that's where we
    # inject the race: the real `lock!` reload would pick up the concurrent
    # write the same way.
    allow(stale).to receive(:lock!) { stale.update_column(:state, "closed") }

    result = described_class.call([ stale, fresh ], via: "bulk", by_user: user)

    expect(result).to be_success
    expect(result.approved).to contain_exactly(fresh)
    expect(result.failed).to contain_exactly(stale)
    expect(stale.reload).to be_closed
    expect(stale.approved_via).to be_nil
    expect(fresh.reload).to be_approved
  end

  it "reports no successes when every job in the batch loses the race" do
    stale = implemented_job(issue_number: 1)
    allow(stale).to receive(:lock!) { stale.update_column(:state, "closed") }

    result = described_class.call([ stale ], via: "bulk", by_user: user)

    expect(result).not_to be_success
    expect(result.approved).to be_empty
    expect(result.failed).to contain_exactly(stale)
  end
end
