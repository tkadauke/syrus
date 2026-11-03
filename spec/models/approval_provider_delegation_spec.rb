require "rails_helper"

RSpec.describe ApprovalProviderDelegation do
  let(:owner) { Factories.user }
  let(:invocation) do
    Permissions::ApprovalProviderRequest.new(owner:, capability: "k8s.workload@v1", operation: "restart@v1",
      resource_type: "cluster", resource_scope: { cluster_id: 7, namespaces: [ "app" ] },
      effects: [ "operational" ], invocation_fingerprint: "sha256:exact", transcript: [],
      tool_call: {}, policy_chain: [])
  end

  subject(:delegation) do
    described_class.create!(owner_user: owner, provider_key: "reviewer", capability: "k8s.workload@v1",
      resource_type: "cluster", resource_scope: { cluster_id: 7, namespaces: [ "app", "jobs" ] },
      excluded_effects: [ "destructive" ])
  end

  it "covers only the explicitly delegated capability and resource scope" do
    expect(delegation).to be_covers(invocation)
    other = Permissions::ApprovalProviderRequest.new(owner:, capability: "k8s.secret@v1", operation: "read@v1",
      resource_type: "cluster", resource_scope: { cluster_id: 7 }, effects: [ "confidential_read" ],
      invocation_fingerprint: "sha256:other", transcript: [], tool_call: {}, policy_chain: [])
    expect(delegation).not_to be_covers(other)
  end

  it "always excludes core human-only effects" do
    expect(delegation.excluded_effects).to include("financial", "privilege_change", "destructive")
  end

  it "does not treat a missing or empty array scope as bounded" do
    missing = invocation_with_scope(cluster_id: 7)
    empty = invocation_with_scope(cluster_id: 7, namespaces: [])

    expect(delegation).not_to be_covers(missing)
    expect(delegation).not_to be_covers(empty)
  end

  it "revokes with human attribution" do
    delegation.revoke!(actor: owner)
    expect(delegation).to have_attributes(revoked_by_user: owner)
    expect(delegation.revoked_at).to be_present
    expect(delegation).not_to be_covers(invocation)
  end

  def invocation_with_scope(scope)
    Permissions::ApprovalProviderRequest.new(owner:, capability: invocation.capability,
      operation: invocation.operation, resource_type: invocation.resource_type, resource_scope: scope,
      effects: invocation.effects, invocation_fingerprint: "sha256:scope", transcript: [],
      tool_call: {}, policy_chain: [])
  end
end
