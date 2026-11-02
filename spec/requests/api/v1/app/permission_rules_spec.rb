require "rails_helper"

RSpec.describe "API: /api/v1/app/permission_rules", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) unless RSpec.current_example.metadata[:skip_sign_in] }

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
    expect(payload.fetch("inherited")).to all(include("requestable_roles", "authority_durations"))
    expect(payload.fetch("inherited")).to all(include("matrix_states" => include(
      "interactive_chat", "coding_chat", "local_chat"
    )))
  end

  it "shows current leases and a redacted, user-scoped authorization history" do
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    other_user = Factories.user
    lease = PermissionLease.create!(
      owner_user: user, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      subject_repository: repository, capability: "syrus.jobs@v1", operation: "cancel@v1",
      resource_type: "job", resource_scope: { job_id: job.id }, constraints: {}, effects: [],
      duration_kind: "job", job:, issued_by_user: user, max_uses: 3, used_count: 1
    )
    PermissionLease.create!(
      owner_user: other_user, subject_selector_type: "interactive_chat", capability: "hidden@v1",
      resource_type: "none", resource_scope: {}, constraints: {}, effects: [],
      duration_kind: "invocation", invocation_fingerprint: "other", issued_by_user: other_user, max_uses: 1
    )
    request = ChatPendingAction.create!(
      request_kind: "authorization_request", user:, repository:, origin: job, subject: user,
      deduplication_key: "history-request", purpose: "Cancel a stuck job"
    )
    item = request.authorization_items.create!(
      kind: "operation", capability: "syrus.jobs@v1", operation: "cancel@v1", operation_version: 1,
      resource_type: "job", resource_scope: { job_id: job.id },
      normalized_arguments: { "api_token" => "secret-value", "job_id" => job.id },
      invocation_fingerprint: "history-fingerprint", effects: [ "internal_write" ], policy_chain: [],
      decisive_rule: {}, requested_durations: [ "job" ]
    )
    item.decide!("approved", principal: user, duration: "job", resulting_authority: lease)
    request.occurrences.create!(origin: user, metadata: {})
    permission_rule(owner: user, descriptor: Permissions::Catalog.descriptors.first)

    get "/api/v1/app/permission_rules/history"

    expect(response).to have_http_status(:ok)
    payload = JSON.parse(response.body)
    expect(payload.fetch("active_leases")).to contain_exactly(include(
      "id" => lease.id, "used_count" => 1, "max_uses" => 3,
      "origin" => include("type" => "Job", "id" => job.id)
    ))
    request_entry = payload.fetch("history").find { |entry| entry["type"] == "request" }
    expect(request_entry).to include("state" => "pending", "escalated" => true)
    expect(request_entry.dig("items", 0, "state")).to eq("approved")
    expect(request_entry.dig("items", 0, "evidence")).to eq("api_token" => "[redacted]", "job_id" => job.id)
    expect(payload.fetch("history")).to include(include("type" => "policy_change", "state" => "created"))
    expect(payload.to_json).not_to include("hidden@v1", "secret-value")
  end

  it "rejects workflow invocation credentials before exposing user-wide history", :skip_sign_in do
    repository = Factories.repository(user: user)
    job = Factories.job_with_run(repository:, user:, run_attrs: { state: "running" })
    token = McpInvocationContext.issue_for_app_run(job.runs.first, expires_in: 5.minutes)

    get "/api/v1/app/permission_rules/history", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("forbidden")
  end

  it "bounds active leases in the history payload" do
    now = Time.current
    PermissionLease.insert_all!(Array.new(Permissions::HistoryPayload::LIMIT + 1) do |index|
      {
        owner_user_id: user.id, subject_selector_type: "interactive_chat",
        capability: "test.read@v1", operation: "read@v1", resource_type: "none",
        resource_scope: {}, constraints: {}, effects: [], duration_kind: "invocation",
        invocation_fingerprint: "history-lease-#{index}", issued_by_user_id: user.id,
        max_uses: 1, used_count: 0, created_at: now + index.seconds, updated_at: now
      }
    end)

    get "/api/v1/app/permission_rules/history"

    expect(response).to have_http_status(:ok)
    active_leases = JSON.parse(response.body).fetch("active_leases")
    expect(active_leases.size).to eq(Permissions::HistoryPayload::LIMIT)
    expect(active_leases.first.fetch("origin")).to be_nil
  end

  it "uses the policy evaluator for matrix states and marks resource-dependent outcomes" do
    descriptor = Permissions::Catalog.descriptors.find { |candidate| candidate.resource_scope.type == :none }
    permission_rule(owner: user, descriptor:, policy: "deny")
    permission_rule(owner: user, descriptor:, policy: "allow")

    get "/api/v1/app/permission_rules"

    inherited = JSON.parse(response.body).fetch("inherited").find do |candidate|
      candidate["capability"] == descriptor.capability && candidate["operation"] == descriptor.operation
    end
    expect(inherited.dig("matrix_states", "interactive_chat")).to eq("deny")

    PermissionRule.where(owner_user: user).find_each { |rule| rule.revoke!(actor: user) }
    permission_rule(owner: user, descriptor:, policy: "allow", resource_scope: { resource_id: "one" })

    get "/api/v1/app/permission_rules"

    inherited = JSON.parse(response.body).fetch("inherited").find do |candidate|
      candidate["capability"] == descriptor.capability && candidate["operation"] == descriptor.operation
    end
    expect(inherited.dig("matrix_states", "interactive_chat")).to eq("scoped")
  end

  it "creates a permanent allow rule for an eligible capability" do
    descriptor = Permissions::Catalog.descriptors.find do |candidate|
      candidate.authority_durations.include?(:permanent) && candidate.requestable_roles.include?(AgentRole::CHAT_PLANNER)
    end

    post "/api/v1/app/permission_rules", params: { permission_rule: {
      policy: "allow", role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation,
      resource_scope: {}, constraints: {}, rationale: "Allow durable access"
    } }

    expect(response).to have_http_status(:created)
    rule = PermissionRule.find(JSON.parse(response.body).dig("rule", "id"))
    expect(rule).to have_attributes(owner_user: user, policy: "allow", policy_layer: "agent")
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

  it "edits a rule by preserving the superseded rule and creating its replacement" do
    original = permission_rule(owner: user)
    descriptor = Permissions::Catalog.descriptors.find do |candidate|
      candidate.authority_durations.include?(:permanent) && candidate.requestable_roles.include?(AgentRole::CHAT_PLANNER)
    end

    patch "/api/v1/app/permission_rules/#{original.id}", params: { permission_rule: {
      policy: "allow", role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation,
      resource_scope: {}, constraints: {}, rationale: "Revised authority"
    } }

    expect(response).to have_http_status(:ok)
    expect(original.reload.revoked_at).to be_present
    replacement = PermissionRule.find(JSON.parse(response.body).dig("rule", "id"))
    expect(replacement).to have_attributes(rationale: "Revised authority", revoked_at: nil)
  end

  it "previews and atomically applies confirmed bulk changes" do
    descriptor = Permissions::Catalog.descriptors.find do |candidate|
      candidate.authority_durations.include?(:permanent) && candidate.requestable_roles.include?(AgentRole::CHAT_PLANNER)
    end
    operations = [ {
      action: "grant", policy: "allow", role: AgentRole::CHAT_PLANNER,
      subject_selector_type: "interactive_chat", capability: descriptor.capability,
      operation: descriptor.operation, resource_scope: {}, constraints: {}
    } ]

    post "/api/v1/app/permission_rules/preview_bulk", params: { operations: }

    expect(response).to have_http_status(:ok)
    preview = JSON.parse(response.body)
    expect(preview.fetch("preview")).to contain_exactly(include(
      "action" => "grant", "capability" => descriptor.capability,
      "resource_scope_label" => a_kind_of(String)
    ))

    expect {
      post "/api/v1/app/permission_rules/bulk", params: {
        operations:, confirmation_digest: preview.fetch("confirmation_digest")
      }
    }.to change(PermissionRule, :count).by(1)
    expect(response).to have_http_status(:ok)
  end

  it "rejects a bulk change when the confirmed preview does not match" do
    rule = permission_rule(owner: user)
    post "/api/v1/app/permission_rules/bulk", params: {
      operations: [ { action: "revoke", id: rule.id } ], confirmation_digest: "stale"
    }

    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("stale_permission_preview")
    expect(rule.reload.revoked_at).to be_nil
  end

  it "rejects bulk operation members that are not objects" do
    post "/api/v1/app/permission_rules/preview_bulk", params: { operations: [ nil ] }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("invalid_permission_bulk")
  end

  def permission_rule(owner:, descriptor: nil, policy: "allow", resource_scope: {})
    PermissionRule.create!(
      owner_user: owner, created_by_user: owner, updated_by_user: owner,
      subject_selector_type: "interactive_chat", capability: descriptor&.capability || "test.read@v1",
      operation: descriptor&.operation || "read@v1", resource_type: descriptor&.resource_scope&.type&.to_s || "none",
      resource_scope:, constraints: {}, policy:,
      policy_layer: "agent", source: "operator", provenance: {}, subject_role_keys: []
    )
  end
end
