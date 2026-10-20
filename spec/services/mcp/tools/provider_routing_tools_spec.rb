require "rails_helper"

RSpec.describe "Mcp::Tools provider routing tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:context) { { chat_session: chat_session } }

  before do
    allow(AgentProviders.for("claude")).to receive(:available_models).and_return([])
    allow(AgentProviders.for("codex")).to receive(:available_models).and_return([])
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "reads only the current user's rules and includes a revision and registry options" do
    rule = ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, user: user, enabled: false, candidates: [ { provider: "claude" } ])

    response = Mcp::Tools::ReadProviderRoutingRulesTool.call(scope_type: "user", server_context: context)

    expect(response).not_to be_error
    expect(payload(response)).to include(
      revision: a_string_matching(/\A[0-9a-f]{64}\z/),
      rules: [ a_hash_including(id: rule.id, enabled: false) ],
      registry_options: a_hash_including(agent_providers: include(a_hash_including(value: "claude")))
    )
  end

  it "rejects a repository the caller cannot manage" do
    other = Factories.repository

    response = Mcp::Tools::ReadProviderRoutingRulesTool.call(scope_type: "repository", repository_id: other.id, server_context: context)

    expect(response).to be_error
  end

  it "explains disabled skips, match failures, and the winning rule" do
    job = Factories.job(repository: repository, user: user, job_provider_setting: "default")
    ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, enabled: false, candidates: [ { provider: "codex" } ])
    ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, position: 2, task_key: "rebase", candidates: [ { provider: "codex" } ])
    ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, position: 3, task_key: "ci_failure", candidates: [ { provider: "claude" } ])

    body = payload(Mcp::Tools::ExplainProviderRoutingTool.call(job_id: job.id, task_key: "ci_failure", server_context: context))
    outcomes = body.fetch(:scope_precedence).flat_map { |scope| scope.fetch(:rules) }.pluck(:outcome)

    expect(outcomes).to eq(%w[disabled_skipped match_failed matched_winner])
    expect(body.dig(:winning_decision, :matched_rule, :id)).to be_present
  end

  it "shows an explicit Job provider pin as overriding every rule" do
    job = Factories.job(repository: repository, user: user, job_provider_setting: "claude", agent_provider: "claude")
    ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, candidates: [ { provider: "codex" } ])

    body = payload(Mcp::Tools::ExplainProviderRoutingTool.call(job_id: job.id, task_key: "implement", server_context: context))

    expect(body.fetch(:explicit_pin)).to include(overrides_rules: true, provider: "claude")
    expect(body.fetch(:scope_precedence).flat_map { |scope| scope.fetch(:rules) }.pluck(:outcome)).to eq([ "overridden_by_explicit_pin" ])
  end

  it "creates a before/after pending action and applies only after confirmation" do
    rule = ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, user: user, candidates: [ { provider: "claude" } ])
    revision = payload(Mcp::Tools::ReadProviderRoutingRulesTool.call(scope_type: "user", server_context: context)).fetch(:revision)

    response = Mcp::Tools::MutateProviderRoutingRulesTool.call(
      scope_type: "user",
      expected_revision: revision,
      operations: [ { type: "set_enabled", id: rule.id, enabled: false } ],
      server_context: context
    )

    expect(response).not_to be_error
    expect(rule.reload).to be_enabled
    pending = ChatPendingAction.find(payload(response).fetch(:pending_action_id))
    expect(pending.payload).to include("before", "after")
    expect(PendingActions::MutateProviderRoutingRules.new(pending).presentation_detail).to include("Before:", "After:")

    pending.confirm!(user: user)
    expect(rule.reload).not_to be_enabled
  end

  it "presents candidate and condition updates distinctly before confirmation" do
    rule = ProviderRoutingRule.create!(
      scope_type: "user",
      scope_id: user.id,
      user: user,
      task_key: "implement",
      candidates: [ { provider: "claude", model: "sonnet", effort_level: "high" } ]
    )
    revision = payload(Mcp::Tools::ReadProviderRoutingRulesTool.call(scope_type: "user", server_context: context)).fetch(:revision)

    response = Mcp::Tools::MutateProviderRoutingRulesTool.call(
      scope_type: "user",
      expected_revision: revision,
      operations: [
        {
          type: "update",
          id: rule.id,
          rule: {
            conditions: { workflow_trigger_kind: [ "pr_comment" ] },
            action: {
              type: "route",
              strategy: "fallback_order",
              candidates: [ { provider: "codex", model: "gpt-5.6", effort_level: "medium" } ]
            }
          }
        }
      ],
      server_context: context
    )

    pending = ChatPendingAction.find(payload(response).fetch(:pending_action_id))
    detail = PendingActions::MutateProviderRoutingRules.new(pending).presentation_detail
    before, after = detail.split("\nBefore: ", 2).last.split("\nAfter: ", 2)

    expect(before).to include("task=implement", 'conditions={}', '"provider":"claude"', '"model":"sonnet"', '"effort_level":"high"')
    expect(after).to include('conditions={"workflow_trigger_kind":["pr_comment"]}', '"provider":"codex"', '"model":"gpt-5.6"', '"effort_level":"medium"')
    expect(after).not_to eq(before)
    expect(rule.reload.action_candidates).to eq([ { "provider" => "claude", "model" => "sonnet", "effort_level" => "high" } ])
  end

  it "fails confirmation if the revision became stale" do
    rule = ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, user: user, candidates: [ { provider: "claude" } ])
    revision = payload(Mcp::Tools::ReadProviderRoutingRulesTool.call(scope_type: "user", server_context: context)).fetch(:revision)
    response = Mcp::Tools::MutateProviderRoutingRulesTool.call(
      scope_type: "user", expected_revision: revision,
      operations: [ { type: "set_enabled", id: rule.id, enabled: false } ], server_context: context
    )
    pending = ChatPendingAction.find(payload(response).fetch(:pending_action_id))
    rule.update!(task_key: "changed")

    expect { pending.confirm!(user: user) }.to raise_error(ProviderRouting::RuleSet::StaleRevision)
    expect(pending.reload).to be_failed
    expect(rule.reload).to be_enabled
  end
end
