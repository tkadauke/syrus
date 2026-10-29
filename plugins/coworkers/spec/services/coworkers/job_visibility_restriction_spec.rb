require "rails_helper"

RSpec.describe Coworkers::JobVisibilityRestriction do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:member) { Factories.user }
  let(:repository_admin) { Factories.user }
  let(:instance_admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: owner) }
  let!(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner,
      name: "Maya",
      handle: "maya-visibility",
      workspace_repo: repository.remote_url
    )
  end
  let!(:task) do
    Factories.job_record(
      repository: repository,
      origin: "coworkers",
      origin_id: coworker.id.to_s,
      issue_title: "Private coworker task"
    )
  end

  before do
    repository.repository_memberships.create!(user: member, role: "read")
    repository.repository_memberships.create!(user: repository_admin, role: "admin")
    repository.repository_memberships.create!(user: instance_admin, role: "read")
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
  end

  it "shows coworker-origin Jobs only to the coworker owner and instance admins" do
    expect(Job.visible_to(owner)).to include(task)
    expect(Job.visible_to(member)).not_to include(task)
    expect(Job.visible_to(repository_admin)).not_to include(task)
    expect(Job.visible_to(instance_admin)).to include(task)
  end

  it "returns an owner-scoped relation suitable for every canonical Job query" do
    other_owner = Factories.user
    other = Coworkers::Coworker.create!(
      owner_user: other_owner,
      name: "Other",
      handle: "other-visibility",
      workspace_repo: repository.remote_url
    )

    visible_ids = described_class.visible_origin_ids(user: owner).pluck(:id)

    expect(visible_ids).to contain_exactly(coworker.id)
    expect(visible_ids).not_to include(other.id)
  end
end
