require "rails_helper"

RSpec.describe Jobs::StateManagement do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def job(state: "implemented", repository: self.repository, **attributes)
    Factories.job_record(user: repository.user, repository:, state:, **attributes)
  end

  def call(job:, action: "close", reason: "No longer needed.", canonical_job: nil)
    described_class.new(job:, action:, reason:, canonical_job:, actor: user, chat_session:).call
  end

  it "closes a duplicate and records its human reason, actor, chat, and canonical Job" do
    duplicate = job
    canonical = job(issue_number: 43)

    result = call(job: duplicate, reason: "QA confirmed the replacement covers this work.", canonical_job: canonical)

    expect(result.job).to have_attributes(state: "closed", closure_reason: "duplicate", canonical_job_id: canonical.id)
    expect(result.transition).to have_attributes(from_state: "implemented", to_state: "closed", source: "operator", user: user)
    expect(result.transition.metadata).to include(
      "actor_type" => "User", "actor_id" => user.id, "chat_session_id" => chat_session.id,
      "human_reason" => "QA confirmed the replacement covers this work.",
      "canonical_job_id" => canonical.id, "requested_action" => "close"
    )
  end

  it "successfully cancels an open Job with a cancelled closure reason" do
    result = call(job: job, action: "cancel", reason: "The request is obsolete.")

    expect(result.job).to have_attributes(state: "closed", closure_reason: "cancelled", canonical_job_id: nil)
    expect(result.transition.metadata).to include(
      "human_reason" => "The request is obsolete.", "requested_action" => "cancel"
    )
  end

  it "rejects landing or deployment evidence without mutation" do
    landed = job(landed_sha: "abc123")
    deployed = job(issue_number: 44)
    deployed.deployment_stage_statuses.create!(stage_name: "staging", reached_at: Time.current)

    expect { call(job: landed) }.to raise_error(described_class::Invalid, /landing or deployment evidence/)
    expect { call(job: deployed) }.to raise_error(described_class::Invalid, /landing or deployment evidence/)
    expect(landed.reload).to be_implemented
    expect(deployed.reload).to be_implemented
  end

  it "rejects a canonical Job from another repository without mutation" do
    duplicate = job
    other_repository = Factories.repository(user: user)

    expect {
      call(job: duplicate, canonical_job: job(repository: other_repository))
    }.to raise_error(described_class::Invalid, /same repository/)
    expect(duplicate.reload).to be_implemented
  end
end
