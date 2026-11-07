require "rails_helper"

RSpec.describe Coworkers::ReviewerTargetProvider do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:workspace_repository) { Factories.repository(user: owner) }

  def coworker(name:, state: "active")
    Coworkers::Coworker.create!(owner_user: owner, name: name, handle: name.downcase,
      state: state, workspace_repo: workspace_repository.remote_url)
  end

  it "resolves only active owner-local coworkers authorized for the repository" do
    authorized = coworker(name: "Maya")
    authorized.grants.create!(capability: "code.read", approval_policy: "auto", scope: [ repository.id ])
    paused = coworker(name: "Paused", state: "paused")
    paused.grants.create!(capability: "code.read", approval_policy: "auto", scope: [ repository.id ])
    unauthorized = coworker(name: "Outside")

    expect(described_class.options(user: owner, repository: repository)).to contain_exactly(
      include(type: "coworker", reference: authorized.id.to_s, display: include("name" => "Maya"))
    )
    expect { described_class.resolve(reference: paused.id, owner: owner, repository: repository) }
      .to raise_error(ActiveRecord::RecordNotFound)
    expect { described_class.resolve(reference: unauthorized.id, owner: owner, repository: repository) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
