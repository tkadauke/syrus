require "rails_helper"

RSpec.describe "API: /api/v1/app/permission_rules", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) }

  it "lists only the signed-in user's rules alongside read-only inherited descriptors" do
    mine = permission_rule(owner: user)
    permission_rule(owner: Factories.user)

    get "/api/v1/app/permission_rules"

    expect(response).to have_http_status(:ok)
    payload = JSON.parse(response.body)
    expect(payload.fetch("rules").pluck("id")).to eq([ mine.id ])
    expect(payload.dig("rules", 0, "editable")).to be(true)
    expect(payload.dig("rules", 0, "owner", "id")).to eq(user.id)
    expect(payload.fetch("inherited")).not_to be_empty
    expect(payload.fetch("inherited")).to all(include("editable" => false, "explanation" => "role_default"))
  end

  it "creates a user-owned deny rule and can revoke it without deleting its history" do
    descriptor = Permissions::Catalog.descriptors.first
    post "/api/v1/app/permission_rules", params: { permission_rule: {
      policy: "deny", role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation,
      resource_scope: {}, constraints: {}, rationale: "Keep this behind approval"
    } }

    expect(response).to have_http_status(:created)
    rule = PermissionRule.find(JSON.parse(response.body).dig("rule", "id"))
    expect(rule).to have_attributes(owner_user: user, policy: "deny", policy_layer: "agent")

    post "/api/v1/app/permission_rules/#{rule.id}/revoke"

    expect(response).to have_http_status(:ok)
    expect(rule.reload.revoked_at).to be_present
    expect(rule.audit_events.pluck(:event_type)).to eq(%w[created revoked])
  end

  it "rejects missing and unsupported policies without creating authority" do
    descriptor = Permissions::Catalog.descriptors.first
    base_params = {
      role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation,
      resource_scope: {}, constraints: {}
    }

    [ nil, "ask", "unexpected" ].each do |policy|
      params = base_params.merge(policy:).compact

      expect {
        post "/api/v1/app/permission_rules", params: { permission_rule: params }
      }.not_to change(PermissionRule, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig("error", "code")).to eq("invalid_permission_rule")
    end
  end

  it "cannot revoke another user's rule" do
    rule = permission_rule(owner: Factories.user)
    post "/api/v1/app/permission_rules/#{rule.id}/revoke"
    expect(response).to have_http_status(:not_found)
  end

  def permission_rule(owner:)
    PermissionRule.create!(
      owner_user: owner, created_by_user: owner, updated_by_user: owner,
      subject_selector_type: "interactive_chat", capability: "test.read@v1", operation: "read@v1",
      resource_type: "none", resource_scope: {}, constraints: {}, policy: "allow",
      policy_layer: "agent", source: "operator", provenance: {}, subject_role_keys: []
    )
  end
end
