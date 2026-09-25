require "rails_helper"

RSpec.describe MainBranchRepairAutoApprover do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, main_branch_repair_auto_approve: true) }

  def repair_job(state: "implemented", **attrs)
    Factories.job_record(
      **{
        user: user,
        repository: repository,
        issue_number: nil,
        issue_title: Job::MAIN_BRANCH_REPAIR_TITLE,
        issue_body: "Fix the broken main branch.",
        kind: "direct",
        state: state,
        system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
        pr_number: 123
      }.merge(attrs)
    )
  end

  it "approves implemented main branch repair jobs when the repository setting is enabled" do
    job = repair_job

    expect(LandingQueueProcessor).to receive(:try_land!).with(job)

    result = described_class.call(job)

    expect(result).to be_approved
    expect(job.reload).to be_approved
    expect(job.approved_via).to eq("auto_rule")
    expect(job.approval_evidence).to eq(
      "rule" => "main_branch_repair_auto_approve",
      "source" => "Repository##{repository.id}"
    )
  end

  it "skips repair jobs when the repository setting is disabled" do
    repository.update!(main_branch_repair_auto_approve: false)
    job = repair_job

    expect(LandingQueueProcessor).not_to receive(:try_land!)

    result = described_class.call(job)

    expect(result).not_to be_approved
    expect(result.reason).to eq("setting_disabled")
    expect(job.reload).to be_implemented
  end

  it "skips regular jobs" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 456)

    expect(LandingQueueProcessor).not_to receive(:try_land!)

    result = described_class.call(job)

    expect(result).not_to be_approved
    expect(result.reason).to eq("not_main_branch_repair")
    expect(job.reload).to be_implemented
  end

  it "runs when a repair job transitions to implemented" do
    job = repair_job(state: "running")

    expect(LandingQueueProcessor).to receive(:try_land!).with(job)

    job.mark_implemented!
    job.save!
    expect(job).to be_implemented
    job.send(:auto_approve_main_branch_repair_after_implementation)

    expect(job.reload).to be_approved
  end
end
