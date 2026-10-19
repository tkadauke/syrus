require "rails_helper"

RSpec.describe ProviderRouting::RuleSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:rule_set) do
    described_class.new(
      scope_type: "repository",
      scope_id: repository.id,
      repository_id: repository.id,
      user_id: user.id
    )
  end

  before do
    allow(AgentProviders.for("claude")).to receive(:available_models).and_return([])
    allow(AgentProviders.for("codex")).to receive(:available_models).and_return([])
  end

  it "previews and atomically applies a complete ordered operation batch" do
    first = ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, candidates: [ { provider: "claude" } ])
    revision = rule_set.snapshot.fetch(:revision)
    operations = [
      { type: "set_enabled", id: first.id, enabled: false },
      { type: "create", rule: { task_key: "implement", candidates: [ { provider: "codex" } ] } }
    ]

    preview = rule_set.mutate!(operations: operations, expected_revision: revision, preview: true)
    expect(preview.fetch(:rules).map { |rule| rule[:enabled] }).to eq([ false, true ])
    expect(first.reload).to be_enabled

    applied = rule_set.mutate!(operations: operations, expected_revision: revision)
    expect(applied.fetch(:rules).pluck(:position)).to eq([ 1, 2 ])
    expect(first.reload).not_to be_enabled
  end

  it "rejects a stale revision without applying any operation" do
    rule = ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, candidates: [ { provider: "claude" } ])
    revision = rule_set.snapshot.fetch(:revision)
    rule.update!(enabled: false)

    expect {
      rule_set.mutate!(operations: [ { type: "delete", id: rule.id } ], expected_revision: revision)
    }.to raise_error(described_class::StaleRevision)
    expect(rule.reload).to be_persisted
  end

  it "supports update, delete, and reorder in one validated transaction" do
    first = ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, candidates: [ { provider: "claude" } ])
    second = ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, position: 2, candidates: [ { provider: "codex" } ])
    deleted = ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, position: 3, task_key: "rebase", candidates: [ { provider: "claude" } ])

    result = rule_set.mutate!(
      expected_revision: rule_set.snapshot.fetch(:revision),
      operations: [
        { type: "update", id: first.id, rule: { task_key: "implement" } },
        { type: "delete", id: deleted.id },
        { type: "reorder", ids: [ second.id, first.id ] }
      ]
    )

    expect(result.fetch(:rules).map { |rule| rule[:id] }).to eq([ second.id, first.id ])
    expect(first.reload.task_key).to eq("implement")
    expect(ProviderRoutingRule.where(id: deleted.id)).to be_empty
  end

  it "rolls back the whole batch when the proposed state is invalid" do
    rule = ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, user: user, repository: repository, candidates: [ { provider: "claude" } ])
    revision = rule_set.snapshot.fetch(:revision)

    expect {
      rule_set.mutate!(
        operations: [
          { type: "set_enabled", id: rule.id, enabled: false },
          { type: "create", rule: { candidates: [ { provider: "not-real" } ] } }
        ],
        expected_revision: revision
      )
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(rule.reload).to be_enabled
  end
end
