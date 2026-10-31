require "rails_helper"

RSpec.describe Coworkers::GrantEscalation do
  let(:owner) { Factories.user }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-scopes", workspace_repo: "git@example.com:workspace.git") }
  let(:descriptor) do
    Coworkers::GrantCatalog::Descriptor.new(
      name: "database.read", label: "Database", description: "Read a database", maximum_policy: "confirm", tools: [ "read_database" ],
      scope_options_callback: ->(user:) { [ user.id, user.id + 1 ] }, scope_label_callback: ->(value) { "Connection #{value}" },
      valid_scope_callback: ->(value, user:) { [ user.id, user.id + 1 ].include?(value) }
    )
  end

  before do
    allow(Coworkers::GrantCatalog).to receive(:fetch).with("database.read").and_return(descriptor)
    allow(Coworkers::GrantCatalog).to receive(:names).and_return(Coworkers::GrantCatalog.names + [ "database.read" ])
  end

  it "persists a scoped grant and presents its scope for confirmation" do
    _coworker, presented = described_class.preflight!(
      owner: owner, coworker_id: coworker.id, grants: [ { capability: "database.read", scope: owner.id } ]
    )
    expect(presented).to eq([ "capability" => "database.read", "scope" => owner.id ])

    described_class.call(owner: owner, coworker_id: coworker.id, grants: presented)
    expect(coworker.grants.find_by!(capability: "database.read")).to have_attributes(scope: owner.id, approval_policy: "confirm")
  end

  it "treats changing an existing scope as an escalation instead of an already-granted error" do
    coworker.grants.create!(capability: "database.read", approval_policy: "confirm", scope: owner.id)
    expect {
      described_class.preflight!(owner: owner, coworker_id: coworker.id,
        grants: [ { capability: "database.read", scope: owner.id + 1 } ])
    }.not_to raise_error
  end
end
