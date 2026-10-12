require "rails_helper"

RSpec.describe "API: /api/v1/app/provider_routing_rules", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 101) }

  before do
    sign_in_as(user)
    user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test")
  end

  def parse_body
    JSON.parse(response.body)
  end

  def create_rule(scope_type:, scope_id:, task_key:, provider: "codex")
    ProviderRoutingRule.create!(
      scope_type: scope_type,
      scope_id: scope_id,
      task_key: task_key,
      candidates: [ { "provider" => provider } ]
    )
  end

  it "creates, updates, and deletes user-scoped routing rules" do
    post "/api/v1/app/credentials/provider_routing_rules",
      params: {
        provider_routing_rule: {
          task_key: "ci_failure",
          candidates: [
            { provider: "codex", model: "gpt-5.2-codex", effort_level: "high" },
            { provider: "claude", model: "claude-sonnet-4-6" }
          ]
        }
      },
      as: :json

    expect(response).to have_http_status(:created)
    rule = ProviderRoutingRule.find_by!(scope_type: "user", scope_id: user.id, task_key: "ci_failure")
    expect(rule.candidates).to eq([
      { "provider" => "codex", "model" => "gpt-5.2-codex", "effort_level" => "high" },
      { "provider" => "claude", "model" => "claude-sonnet-4-6" }
    ])
    expect(parse_body.fetch("provider_routing_rules")).to include(include("id" => rule.id, "task_key" => "ci_failure"))

    patch "/api/v1/app/credentials/provider_routing_rules/#{rule.id}",
      params: {
        provider_routing_rule: {
          task_key: "default",
          candidates: [ { provider: "codex" } ]
        }
      },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(rule.reload.task_key).to eq("default")
    expect(rule.candidates).to eq([ { "provider" => "codex" } ])
    expect(rule.trigger).to eq("type" => "default")
    expect(rule.action).to eq("strategy" => "fallback_order", "candidates" => [ { "provider" => "codex" } ])

    delete "/api/v1/app/credentials/provider_routing_rules/#{rule.id}"

    expect(response).to have_http_status(:ok)
    expect(ProviderRoutingRule.where(id: rule.id)).to be_empty
  end

  it "creates repository-scoped rules for repository admins" do
    post "/api/v1/app/repositories/#{repository.id}/provider_routing_rules",
      params: {
        provider_routing_rule: {
          task_key: "initial",
          candidates: [ { provider: "codex", effort_level: "medium" } ]
        }
      },
      as: :json

    expect(response).to have_http_status(:created)
    rule = ProviderRoutingRule.find_by!(scope_type: "repository", scope_id: repository.id, task_key: "initial")
    expect(rule.candidates).to eq([ { "provider" => "codex", "effort_level" => "medium" } ])
  end

  it "creates, updates, and deletes job-scoped override rules for writable jobs" do
    post "/api/v1/app/jobs/#{job.id}/provider_routing_rules",
      params: {
        provider_routing_rule: {
          trigger: { type: "step", kind: "implement" },
          conditions: { workflow_trigger_kind: [ "initial" ] },
          action: { strategy: "fallback_order", candidates: [ { provider: "codex", model: "gpt-5.2-codex" } ] }
        }
      },
      as: :json

    expect(response).to have_http_status(:created)
    rule = ProviderRoutingRule.find_by!(scope_type: "job", scope_id: job.id)
    expect(rule.repository_id).to eq(repository.id)
    expect(rule.user_id).to eq(user.id)
    expect(rule.trigger).to eq("type" => "step", "kind" => "implement")

    patch "/api/v1/app/jobs/#{job.id}/provider_routing_rules/#{rule.id}",
      params: {
        provider_routing_rule: {
          trigger: { type: "chat_role", role: AgentRole::CHAT_CODING },
          candidates: [ { provider: "claude" } ]
        }
      },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(rule.reload.trigger).to eq("type" => "chat_role", "role" => AgentRole::CHAT_CODING)

    delete "/api/v1/app/jobs/#{job.id}/provider_routing_rules/#{rule.id}"

    expect(response).to have_http_status(:ok)
    expect(ProviderRoutingRule.where(id: rule.id)).to be_empty
  end

  it "returns inherited context for repository and job scopes" do
    user_rule = create_rule(scope_type: "user", scope_id: user.id, task_key: "default")
    repository_rule = create_rule(scope_type: "repository", scope_id: repository.id, task_key: "initial", provider: "claude")
    job_rule = create_rule(scope_type: "job", scope_id: job.id, task_key: "ci_failure")

    get "/api/v1/app/repositories/#{repository.id}/provider_routing_rules"

    expect(response).to have_http_status(:ok)
    repository_body = parse_body
    expect(repository_body.fetch("scope")).to include("type" => "repository", "id" => repository.id)
    expect(repository_body.fetch("provider_routing_rules")).to include(include("id" => repository_rule.id))
    expect(repository_body.fetch("inherited_provider_routing_context")).to contain_exactly(
      include("scope_type" => "user", "scope_id" => user.id, "rules" => include(include("id" => user_rule.id)))
    )

    get "/api/v1/app/jobs/#{job.id}/provider_routing_rules"

    expect(response).to have_http_status(:ok)
    job_body = parse_body
    expect(job_body.fetch("provider_routing_rules")).to include(include("id" => job_rule.id))
    expect(job_body.fetch("inherited_provider_routing_context")).to match(
      [
        include("scope_type" => "repository", "scope_id" => repository.id, "rules" => include(include("id" => repository_rule.id))),
        include("scope_type" => "user", "scope_id" => user.id, "rules" => include(include("id" => user_rule.id)))
      ]
    )
  end

  it "atomically reorders rules within a scope and rejects ids from another scope" do
    first = create_rule(scope_type: "user", scope_id: user.id, task_key: "default")
    second = create_rule(scope_type: "user", scope_id: user.id, task_key: "initial")
    repository_rule = create_rule(scope_type: "repository", scope_id: repository.id, task_key: "ci_failure")

    patch "/api/v1/app/credentials/provider_routing_rules/reorder",
      params: { provider_routing_rule_ids: [ second.id, first.id ] },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(first.reload.position).to eq(2)
    expect(second.reload.position).to eq(1)
    expect(parse_body.fetch("provider_routing_rules").map { |rule| rule.fetch("id") }).to eq([ second.id, first.id ])

    patch "/api/v1/app/credentials/provider_routing_rules/reorder",
      params: { provider_routing_rule_ids: [ first.id, repository_rule.id ] },
      as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(first.reload.position).to eq(2)
    expect(second.reload.position).to eq(1)
  end

  it "applies ordered user rules, repository overrides, and job overrides to the job detail routing resolution" do
    post "/api/v1/app/credentials/provider_routing_rules",
      params: { provider_routing_rule: { trigger: { type: "default" }, action: { strategy: "fallback_order", name: "My Claude default", candidates: [ { provider: "claude" } ] } } },
      as: :json
    expect(response).to have_http_status(:created)
    user_default_rule = ProviderRoutingRule.where(scope_type: "user", scope_id: user.id).detect { |rule| rule.action["name"] == "My Claude default" }

    post "/api/v1/app/credentials/provider_routing_rules",
      params: { provider_routing_rule: { trigger: { type: "step", kind: "implement" }, action: { strategy: "fallback_order", name: "My Codex implementation", candidates: [ { provider: "codex" } ] } } },
      as: :json
    expect(response).to have_http_status(:created)
    user_implement_rule = ProviderRoutingRule.where(scope_type: "user", scope_id: user.id).detect { |rule| rule.action["name"] == "My Codex implementation" }

    patch "/api/v1/app/credentials/provider_routing_rules/reorder",
      params: { provider_routing_rule_ids: [ user_implement_rule.id, user_default_rule.id ] },
      as: :json
    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("provider_routing_rules").map { |rule| rule.fetch("id") }).to eq([ user_implement_rule.id, user_default_rule.id ])

    post "/api/v1/app/repositories/#{repository.id}/provider_routing_rules",
      params: { provider_routing_rule: { trigger: { type: "default" }, action: { strategy: "fallback_order", name: "Repository Claude override", candidates: [ { provider: "claude" } ] } } },
      as: :json
    expect(response).to have_http_status(:created)
    repository_rule = ProviderRoutingRule.find_by!(scope_type: "repository", scope_id: repository.id)

    post "/api/v1/app/jobs/#{job.id}/provider_routing_rules",
      params: { provider_routing_rule: { trigger: { type: "default" }, action: { strategy: "fallback_order", name: "Job Codex override", candidates: [ { provider: "codex", effort_level: "high" } ] } } },
      as: :json
    expect(response).to have_http_status(:created)
    job_rule = ProviderRoutingRule.find_by!(scope_type: "job", scope_id: job.id)

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("job", "provider_routing_rules")).to include(include("id" => job_rule.id, "scope_type" => "job"))
    expect(body.dig("job", "inherited_provider_routing_context")).to include(
      include("scope_type" => "user", "rules" => include(include("id" => user_implement_rule.id))),
      include("scope_type" => "repository", "rules" => include(include("id" => repository_rule.id)))
    )
    expect(body.dig("job", "provider_routing_resolution")).to include(
      "source_scope" => "job",
      "reason" => "matched_rule",
      "matched_rule" => include("id" => job_rule.id),
      "final_action" => include("candidates" => [ include("provider" => "codex", "effort_level" => "high") ])
    )
  end

  it "returns validation failures for unknown triggers and providers" do
    post "/api/v1/app/credentials/provider_routing_rules",
      params: {
        provider_routing_rule: {
          trigger: { type: "step", kind: "not_a_step" },
          candidates: [ { provider: "not-a-provider" } ]
        }
      },
      as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.fetch("error")).to include("code" => "validation_failed")
    expect(parse_body.dig("error", "message")).to include("step kind must be agentic")
    expect(parse_body.dig("error", "message")).to include("unknown provider")
  end

  it "requires write access for job-scoped mutations" do
    reader = Factories.user
    repository.repository_memberships.create!(user: reader, role: "read")
    sign_in_as(reader)

    post "/api/v1/app/jobs/#{job.id}/provider_routing_rules",
      params: {
        provider_routing_rule: {
          candidates: [ { provider: "codex" } ]
        }
      },
      as: :json

    expect(response).to have_http_status(:forbidden)
    expect(ProviderRoutingRule.where(scope_type: "job", scope_id: job.id)).to be_empty
  end

  it "exposes trigger and condition options from live registries" do
    workflow_kind_provider = Class.new do
      include Syrus::Plugin::WorkflowKinds

      def self.trigger_kinds
        [
          { kind: "plugin_review", template: "Initial", label: "Plugin review", style: "bg-gray-100", retry_label: nil, feedback_kind: nil, runtime_role: "first_class" }
        ]
      end

      def self.step_kinds
        [
          { kind: "plugin_agent_step", handler: "Prepare", label: "Plugin agent step", style: "bg-gray-100", agentic: true }
        ]
      end
    end
    Syrus::PluginRegistry.register(name: "provider_routing_rules_spec_plugin", version: "1.0.0", provides: { workflow_kinds: workflow_kind_provider })

    get "/api/v1/app/credentials/provider_routing_rules"

    expect(response).to have_http_status(:ok)
    options = parse_body.fetch("provider_routing_options")
    expect(options.dig("triggers", "chat_roles")).to include(include("value" => AgentRole::CHAT_CODING))
    expect(options.dig("triggers", "step_kinds")).to include(
      include("value" => "implement"),
      include("value" => "plugin_agent_step", "label" => "Plugin agent step")
    )
    expect(options.dig("conditions", "workflow_trigger_kinds")).to include(
      include("value" => "initial"),
      include("value" => "plugin_review", "label" => "Plugin review")
    )
    expect(options.fetch("agent_providers")).to include(include("value" => "codex"))
    expect(options.fetch("effort_levels")).to include(include("value" => "high"))
  end

  it "does not allow non-admin repository members to mutate repository rules" do
    writer = Factories.user
    repository.repository_memberships.create!(user: writer, role: "write")
    sign_in_as(writer)

    post "/api/v1/app/repositories/#{repository.id}/provider_routing_rules",
      params: {
        provider_routing_rule: {
          task_key: "initial",
          candidates: [ { provider: "codex" } ]
        }
      },
      as: :json

    expect(response).to have_http_status(:not_found)
    expect(ProviderRoutingRule.where(scope_type: "repository", scope_id: repository.id)).to be_empty
  end

  it "returns routing rules and provider model catalog in settings payloads" do
    ProviderRoutingRule.create!(
      scope_type: "user",
      scope_id: user.id,
      task_key: "default",
      candidates: [ { "provider" => "codex" } ]
    )
    ProviderRoutingRule.create!(
      scope_type: "repository",
      scope_id: repository.id,
      task_key: "ci_failure",
      candidates: [ { "provider" => "claude" } ]
    )

    get "/api/v1/app/credentials"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("provider_routing_rules")).to include(include("task_key" => "default"))
    expect(parse_body.dig("options", "provider_routing_options", "agent_providers")).to include(
      include("value" => "codex", "models" => include(include("id" => "gpt-5.2-codex")))
    )

    get "/api/v1/app/repositories/#{repository.id}/edit"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("provider_routing_rules")).to include(include("task_key" => "ci_failure"))
    expect(parse_body.fetch("inherited_provider_routing_context")).to include(
      include("scope_type" => "user", "label" => "User defaults", "rules" => include(include("task_key" => "default")))
    )
    expect(parse_body.dig("provider_routing_options", "agent_providers")).to include(
      include("value" => "claude", "models" => include(include("id" => "claude-sonnet-4-6")))
    )
  end
end
