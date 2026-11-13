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
    expect(payload.fetch("inherited")).to all(include("presentation" => include("capability_name", "operation_name")))
    expect(payload.fetch("profiles").pluck("key")).to eq(%w[full_access@v1 ask_on_first_use@v1 restricted@v1])
    expect(payload.fetch("permission_hub_mode")).to eq("simple")
    expect(payload.fetch("current_profiles")).to include("interactive_chat" => nil)
    expect(payload.fetch("inherited")).to all(include("matrix_states" => include(
      "interactive_chat", "coding_chat", "local_chat"
    )))
  end

  it "atomically replaces one chat surface's custom rules with a canonical profile" do
    descriptor = Permissions::Catalog.descriptors.find { |candidate| candidate.requestable_roles.include?(AgentRole::CHAT_PLANNER) }
    old_rule = permission_rule(owner: user, descriptor:, resource_scope: { "repository_id" => 42 })

    post "/api/v1/app/permission_rules/preview_profile", params: {
      profile: "restricted@v1", subject_selector_type: "interactive_chat"
    }

    expect(response).to have_http_status(:ok)
    preview = JSON.parse(response.body)
    expect(preview.dig("preview", "profile", "key")).to eq("restricted@v1")
    expect(preview.dig("preview", "revoked")).to contain_exactly(include(
      "id" => old_rule.id, "capability" => old_rule.capability,
      "resource_scope" => { "repository_id" => 42 }, "resource_scope_label" => a_kind_of(String)
    ))
    expect(preview.dig("preview", "replacements")).to include(include(
      "capability" => descriptor.capability, "operation" => descriptor.operation, "policy" => "deny"
    ))

    post "/api/v1/app/permission_rules/apply_profile", params: {
      profile: "restricted@v1", subject_selector_type: "interactive_chat",
      confirmation_digest: preview.fetch("confirmation_digest")
    }

    expect(response).to have_http_status(:ok)
    expect(old_rule.reload.revoked_at).to be_present
    active = PermissionRule.for_owner(user).active.where(subject_selector_type: "interactive_chat")
    expect(active).not_to be_empty
    expect(active.pluck(:source).uniq).to eq([ "permission_profile:restricted@v1" ])
    expect(JSON.parse(response.body)).to include("profile" => "restricted@v1", "subject_selector_type" => "interactive_chat")

    get "/api/v1/app/permission_rules"
    expect(JSON.parse(response.body).dig("current_profiles", "interactive_chat")).to eq("restricted@v1")
  end

  it "rejects a profile application when scoped rules changed after preview" do
    descriptor = Permissions::Catalog.descriptors.find { |candidate| candidate.requestable_roles.include?(AgentRole::CHAT_PLANNER) }
    old_rule = permission_rule(owner: user, descriptor:)

    post "/api/v1/app/permission_rules/preview_profile", params: {
      profile: "full_access@v1", subject_selector_type: "interactive_chat"
    }
    digest = JSON.parse(response.body).fetch("confirmation_digest")
    old_rule.revise!(actor: user, rationale: "changed after preview")

    post "/api/v1/app/permission_rules/apply_profile", params: {
      profile: "full_access@v1", subject_selector_type: "interactive_chat", confirmation_digest: digest
    }

    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("stale_permission_preview")
    expect(old_rule.reload.revoked_at).to be_nil
  end

  it "rejects unknown profiles and subjects without changing rules" do
    rule = permission_rule(owner: user)

    post "/api/v1/app/permission_rules/preview_profile", params: {
      profile: "unknown@v1", subject_selector_type: "interactive_chat"
    }
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/app/permission_rules/preview_profile", params: {
      profile: "restricted@v1", subject_selector_type: "unknown"
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(rule.reload.revoked_at).to be_nil
  end

  it "shows current leases and a redacted, user-scoped authorization history" do
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    job.update!(issue_title: "Stuck deployment")
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
    request.authorization_items.create!(
      kind: "capability_possession", capability: "unrelated.capability@v1",
      resource_type: "none", resource_scope: {}, normalized_arguments: {}, effects: [],
      policy_chain: [], decisive_rule: {}, requested_durations: [ "job" ]
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
    approved_item = request_entry.fetch("items").find { |entry| entry["capability"] == "syrus.jobs@v1" }
    expect(approved_item.fetch("state")).to eq("approved")
    expect(approved_item.fetch("evidence")).to eq("api_token" => "[redacted]", "job_id" => job.id)
    expect(payload.fetch("history")).to include(include("type" => "policy_change", "state" => "created"))
    expect(payload.to_json).not_to include("hidden@v1", "secret-value")

    filter = Filters::QueryParam.encode("and" => [
      { "field" => "capability", "op" => "is", "value" => "syrus.jobs@v1" },
      { "field" => "outcome", "op" => "is_one_of", "value" => [ "approved" ] },
      { "field" => "actor", "op" => "contains", "value" => user.email_address },
      { "field" => "context", "op" => "contains", "value" => job.title },
      { "field" => "occurred_at", "op" => "between", "value" => [ 1.hour.ago.iso8601, 1.hour.from_now.iso8601 ] }
    ])
    get "/api/v1/app/permission_rules/history", params: { q: filter }

    filtered = JSON.parse(response.body).fetch("history")
    expect(filtered).to contain_exactly(include("type" => "request", "id" => request.id))
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
    PermissionLease.insert_all!(Array.new(Permissions::HistoryPayload::PER_PAGE + 1) do |index|
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
    expect(active_leases.size).to eq(Permissions::HistoryPayload::PER_PAGE)
    expect(active_leases.first.fetch("origin")).to be_nil
  end

  it "paginates and filters permission history with the shared filter AST" do
    descriptor = Permissions::Catalog.descriptors.first
    other_descriptor = Permissions::Catalog.descriptors.find { |candidate| candidate.capability != descriptor.capability }
    (Permissions::HistoryPayload::PER_PAGE + 1).times do |index|
      permission_rule(owner: user, descriptor:, policy: index.zero? ? "deny" : "allow")
    end
    # Newer non-matches fill the old per-source fetch window. The filtered
    # query must still find and paginate the older matching decisions.
    (Permissions::HistoryPayload::PER_PAGE + 1).times do
      permission_rule(owner: user, descriptor: other_descriptor)
    end
    filter = Filters::QueryParam.encode("and" => [
      { "field" => "capability", "op" => "is", "value" => descriptor.capability },
      { "field" => "outcome", "op" => "is", "value" => "created" },
      { "field" => "actor", "op" => "contains", "value" => user.email_address },
      { "field" => "occurred_at", "op" => "within_last", "value" => { "n" => 1, "unit" => "days" } }
    ])

    get "/api/v1/app/permission_rules/history", params: { q: filter, page: 1 }

    expect(response).to have_http_status(:ok)
    payload = JSON.parse(response.body)
    expect(payload.fetch("history").size).to eq(Permissions::HistoryPayload::PER_PAGE)
    expect(payload.fetch("history")).to all(include("type" => "policy_change", "capability" => descriptor.capability, "state" => "created"))
    expect(payload.dig("history_pagination", "page")).to eq(1)
    expect(payload.fetch("history_pagination")).to include("total" => 26, "total_pages" => 2, "has_more" => true)
    expect(payload.fetch("filter")).to eq(Filters::QueryParam.decode(filter))
    expect(payload.fetch("filter_schema").map { |field| field.fetch("field") }).to eq(%w[capability outcome actor context occurred_at])

    get "/api/v1/app/permission_rules/history", params: { q: filter, page: 2 }
    second_page = JSON.parse(response.body)
    expect(second_page.fetch("history").size).to eq(1)
    expect(second_page.fetch("history_pagination")).to include("total" => 26, "total_pages" => 2, "has_more" => false)
  end

  it "uses the policy evaluator for matrix states and marks resource-dependent outcomes" do
    # An auto-allowed default would make an allow rule indistinguishable from the
    # default, so pick a descriptor that does not already allow by default.
    descriptor = Permissions::Catalog.descriptors.find do |candidate|
      candidate.resource_scope.type == :none && candidate.defaults.values.none?(:allow)
    end
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
