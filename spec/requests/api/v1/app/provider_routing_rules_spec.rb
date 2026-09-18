require "rails_helper"

RSpec.describe "API: /api/v1/app/provider_routing_rules", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    sign_in_as(user)
    user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test")
  end

  def parse_body
    JSON.parse(response.body)
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
    expect(parse_body.dig("provider_routing_options", "agent_providers")).to include(
      include("value" => "claude", "models" => include(include("id" => "claude-sonnet-4-6")))
    )
  end
end
