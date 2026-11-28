require "rails_helper"

RSpec.describe Coworkers::JobAutonomyComparison do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-shadow", workspace_repo: repository.remote_url) }
  let(:job) { Factories.job_record(user: owner, repository:, filed_by_coworker_id: coworker.id) }
  let(:rule) do
    coworker.permission_rules.update!(capability: "coworker.jobs.cancel", approval_policy: "auto", actor: owner,
      scope: repository.id, constraints: Coworkers::JobAutonomy::DEFAULTS).first
  end

  def pending(state)
    action = ChatPendingAction.create!(user: owner, repository:, action: "cancel_job", payload: { "job_id" => job.id }, before_snapshot: {}, after_snapshot: {})
    action.update_columns(state:, confirmed_at: (Time.current if state == "confirmed"), rejected_at: (Time.current if state == "rejected"))
    action
  end

  def shadow(state)
    coworker.job_autonomy_shadow_decisions.create!(permission_rule: rule, repository:, chat_pending_action: pending(state),
      action: "cancel_job", predicted_decision: "act", evidence: { "job_id" => 12 },
      guardrail_outcomes: { "budget" => { "passed" => true } })
  end

  it "pairs shadow decisions with later operator decisions and computes agreement" do
    agreed = shadow("confirmed")
    disagreed = shadow("rejected")

    result = described_class.call(coworker:)

    expect(result.dig("actions", "cancel_job")).to include("paired" => 2, "agreed" => 1, "disagreed" => 1, "agreement_rate" => 0.5)
    expect(result.fetch("disagreements").map { |item| item.fetch("id") }).to eq([ disagreed.id ])
    expect(agreed.reload.operator_decision).to eq("act")
    expect(disagreed.reload.operator_decision).to eq("abstain")
  end
end
