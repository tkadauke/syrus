require "rails_helper"

RSpec.describe Coworkers::JobAutonomy do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:other_repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-autonomy", workspace_repo: repository.remote_url)
  end
  let(:own_job) { Factories.job_record(user: owner, repository:, filed_by_coworker_id: coworker.id) }

  def grant!(tool_name, repository_id: repository.id)
    capability = described_class::CAPABILITIES.fetch(tool_name)
    coworker.permission_rules.update!(
      capability:, approval_policy: "auto", scope: repository_id, actor: owner
    )
  end

  it "allows each scoped action only for the coworker's own Job" do
    described_class::CAPABILITIES.each_key { |tool_name| grant!(tool_name) }

    described_class::CAPABILITIES.each_key do |tool_name|
      decision = described_class.new(coworker).authorize(tool_name:, repository:, job: (own_job unless tool_name == "propose_job"))
      expect(decision).to be_allowed
      expect(decision.rule).to be_present
    end
  end

  it "refuses another coworker's Job and a repository outside the rule scope" do
    grant!("approve_job")
    foreign_job = Factories.job_record(user: owner, repository:)
    other_job = Factories.job_record(user: owner, repository: other_repository, filed_by_coworker_id: coworker.id)

    expect(described_class.new(coworker).authorize(tool_name: "approve_job", repository:, job: foreign_job)).not_to be_allowed
    expect(described_class.new(coworker).authorize(tool_name: "approve_job", repository: other_repository, job: other_job)).not_to be_allowed
  end

  it "does nothing without an allow grant" do
    expect(described_class.new(coworker).authorize(tool_name: "cancel_job", repository:, job: own_job)).not_to be_allowed
  end
end
