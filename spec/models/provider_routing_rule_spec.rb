require "rails_helper"

RSpec.describe ProviderRoutingRule do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, user: user, owner_user: user, job_provider_setting: "default") }

  def rule(**attrs)
    described_class.new({
      scope_type: "repository",
      scope_id: repository.id,
      user_id: user.id,
      repository_id: repository.id,
      task_key: "default",
      position: 1,
      candidates: [ { "provider" => "claude" } ]
    }.merge(attrs))
  end

  it "is valid with a well-formed repository-scoped rule" do
    expect(rule).to be_valid
  end

  it "defaults new rules to enabled" do
    expect(rule).to be_enabled
  end

  it "is valid with a well-formed user-scoped rule" do
    expect(rule(scope_type: "user", scope_id: user.id, user_id: user.id, repository_id: nil)).to be_valid
  end

  it "is valid with a well-formed job-scoped rule" do
    expect(rule(scope_type: "job", scope_id: job.id, job_id: job.id, repository_id: repository.id)).to be_valid
  end

  it "requires a known scope_type" do
    record = rule(scope_type: "epic")

    expect(record).not_to be_valid
    expect(record.errors[:scope_type]).to be_present
  end

  it "requires scope_id" do
    record = rule(scope_id: nil)

    expect(record).not_to be_valid
    expect(record.errors[:scope_id]).to be_present
  end

  it "requires consistent user ownership" do
    record = rule(user_id: user.id + 1000)

    expect(record).not_to be_valid
    expect(record.errors[:user_id]).to be_present
  end

  it "enforces uniqueness on (scope_type, scope_id, position)" do
    rule(task_key: "ci_failure").save!

    duplicate = rule(task_key: "default")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:position]).to be_present
  end

  it "allows the same trigger across different ordered rules in one scope" do
    rule(task_key: "ci_failure", position: 1).save!

    expect(rule(task_key: "ci_failure", position: 2)).to be_valid
  end

  it "defaults payloads from legacy task_key and candidates" do
    record = described_class.new(scope_type: "repository", scope_id: repository.id, user_id: user.id, repository_id: repository.id, task_key: "initial")

    expect(record).to be_valid
    expect(record.candidates).to eq([])
    expect(record.trigger).to eq("type" => "legacy_task", "task_key" => "initial")
    expect(record.action).to eq("strategy" => "fallback_order", "candidates" => [])
  end

  it "rejects a candidates value that is not an array" do
    record = rule(candidates: { "provider" => "claude" })

    expect(record).not_to be_valid
    expect(record.errors[:candidates]).to be_present
  end

  it "rejects a candidate entry that is not an object" do
    record = rule(candidates: [ "claude" ])

    expect(record).not_to be_valid
    expect(record.errors[:candidates]).to be_present
  end

  it "rejects a candidate missing a provider" do
    record = rule(candidates: [ { "model" => "sonnet" } ])

    expect(record).not_to be_valid
    expect(record.errors[:candidates]).to be_present
  end

  it "rejects a candidate with an unknown provider" do
    record = rule(candidates: [ { "provider" => "not-a-real-provider" } ])

    expect(record).not_to be_valid
    expect(record.errors[:candidates]).to be_present
  end

  it "accepts actual invocation triggers for agentic step kinds and chat roles" do
    step_rule = rule(trigger: { type: "step", kind: "implement" })
    chat_rule = rule(position: 2, trigger: { type: "chat_role", role: AgentRole::CHAT_PLANNER })

    expect(step_rule).to be_valid
    expect(chat_rule).to be_valid
  end

  it "rejects trigger shapes that do not represent agent invocations" do
    non_agentic = rule(trigger: { type: "step", kind: "prepare" })
    unknown_chat_role = rule(trigger: { type: "chat_role", role: "chat:not-real" })

    expect(non_agentic).not_to be_valid
    expect(non_agentic.errors[:trigger]).to be_present
    expect(unknown_chat_role).not_to be_valid
    expect(unknown_chat_role.errors[:trigger]).to be_present
  end

  it "rejects malformed condition payloads" do
    record = rule(conditions: {
      "workflow_trigger_kind" => "not-real",
      "day_time" => { "days" => [ "nonday" ], "start" => "9am" },
      "repository" => { "ids" => "not-array" },
      "job_metadata" => "not-object"
    })

    expect(record).not_to be_valid
    expect(record.errors[:conditions]).to be_present
  end

  it "accepts structured conditions for workflow, budget, day, repository, and job metadata predicates" do
    record = rule(conditions: {
      workflow_trigger_kind: [ "initial" ],
      usage: { "max_daily_cost_usd" => 10 },
      budget: { "remaining_percent_greater_than" => 20 },
      day_time: { "days" => [ "monday" ], "start" => "09:00", "end" => "17:00" },
      repository: { "ids" => [ repository.id ], "owners" => [ repository.owner ], "names" => [ repository.name ] },
      job_metadata: { "kinds" => [ "issue" ], "priorities" => [ "medium" ] }
    })

    expect(record).to be_valid
  end

  it "rejects malformed action payloads" do
    missing_candidates = rule(action: { strategy: "fallback_order" })
    unknown_strategy = rule(action: { strategy: "round_robin", candidates: [ { provider: "claude" } ] })

    expect(missing_candidates).not_to be_valid
    expect(missing_candidates.errors[:action]).to be_present
    expect(unknown_strategy).not_to be_valid
    expect(unknown_strategy.errors[:action]).to be_present
  end

  it "accepts weighted action payloads for future load balancing" do
    record = rule(action: {
      strategy: "weighted",
      candidates: [
        { provider: "claude", weight: 75 },
        { provider: "codex", weight: 25 }
      ]
    })

    expect(record).to be_valid
  end

  it "accepts a hold action without provider candidates" do
    record = rule(candidates: [], action: { type: "hold", reason: "Await operator approval" })

    expect(record).to be_valid
    expect(record).to be_hold_action
    expect(record.action_candidates).to eq([])
    expect(record.serialized_action).to eq("type" => "hold", "reason" => "Await operator approval")
  end

  it "rejects unknown action types and malformed hold reasons" do
    unknown = rule(action: { type: "delegate" })
    malformed_hold = rule(action: { type: "hold", reason: { message: "wait" } })

    expect(unknown).not_to be_valid
    expect(unknown.errors[:action].join).to include("unknown type")
    expect(malformed_hold).not_to be_valid
    expect(malformed_hold.errors[:action].join).to include("reason must be a string")
  end

  it "serializes legacy route actions with an explicit discriminator" do
    record = rule(action: { strategy: "fallback_order", candidates: [ { provider: "claude" } ] })

    expect(record).to be_valid
    expect(record.serialized_action).to include("type" => "route", "strategy" => "fallback_order")
  end

  it "validates repository and job scoped rule ownership" do
    other_user = Factories.user
    repository_rule = rule(user_id: other_user.id)
    job_rule = rule(scope_type: "job", scope_id: job.id, job_id: job.id, user_id: other_user.id)

    expect(repository_rule).not_to be_valid
    expect(repository_rule.errors[:user_id]).to be_present
    expect(job_rule).not_to be_valid
    expect(job_rule.errors[:user_id]).to be_present
  end

  it "accepts an ordered multi-candidate fallback chain across known providers" do
    record = rule(candidates: [
      { "provider" => "claude", "model" => "claude-sonnet-4-6", "effort_level" => "high" },
      { "provider" => "codex" }
    ])

    expect(record).to be_valid
  end

  # Regression: codex publishes a catalog, so this validation is live for it.
  # A model the account can actually use is still unconfigurable until it is
  # listed, which is a real failure mode when a provider changes which
  # models it accepts.
  it "accepts codex's default model, which must be in its published catalog" do
    record = rule(candidates: [ { "provider" => "codex", "model" => CodexInvocation::DEFAULT_MODEL } ])

    expect(record).to be_valid
  end

  it "rejects a codex candidate naming a model outside its published catalog" do
    record = rule(candidates: [ { "provider" => "codex", "model" => "gpt-9.9-imaginary" } ])

    expect(record).not_to be_valid
    expect(record.errors[:candidates].join).to include("not in codex's known models")
  end

  it "does not hard-fail on an unrecognized model when the provider has no model catalog yet" do
    allow(AgentProviders.for("claude")).to receive(:available_models).and_return([])
    record = rule(candidates: [ { "provider" => "claude", "model" => "not-a-real-model" } ])

    expect(record).to be_valid
  end

  it "softly enforces a model against a provider's catalog once the provider implements one" do
    allow(AgentProviders.for("claude")).to receive(:available_models).and_return([ "sonnet", "opus" ])

    valid_record = rule(candidates: [ { "provider" => "claude", "model" => "sonnet" } ])
    invalid_record = rule(candidates: [ { "provider" => "claude", "model" => "not-a-real-model" } ])

    expect(valid_record).to be_valid
    expect(invalid_record).not_to be_valid
    expect(invalid_record.errors[:candidates]).to be_present
  end
end
