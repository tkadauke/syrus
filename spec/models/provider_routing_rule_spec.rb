require "rails_helper"

RSpec.describe ProviderRoutingRule do
  def rule(**attrs)
    described_class.new({
      scope_type: "repository",
      scope_id: 1,
      task_key: "default",
      candidates: [ { "provider" => "claude" } ]
    }.merge(attrs))
  end

  it "is valid with a well-formed repository-scoped rule" do
    expect(rule).to be_valid
  end

  it "is valid with a well-formed user-scoped rule" do
    expect(rule(scope_type: "user")).to be_valid
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

  it "requires task_key" do
    record = rule(task_key: nil)

    expect(record).not_to be_valid
    expect(record.errors[:task_key]).to be_present
  end

  it "enforces uniqueness on (scope_type, scope_id, task_key)" do
    rule(scope_type: "repository", scope_id: 7, task_key: "ci_failure").save!

    duplicate = rule(scope_type: "repository", scope_id: 7, task_key: "ci_failure")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:task_key]).to be_present
  end

  it "allows the same task_key across different scope types or ids" do
    rule(scope_type: "repository", scope_id: 7, task_key: "ci_failure").save!

    expect(rule(scope_type: "repository", scope_id: 8, task_key: "ci_failure")).to be_valid
    expect(rule(scope_type: "user", scope_id: 7, task_key: "ci_failure")).to be_valid
  end

  it "defaults candidates to an empty array" do
    record = described_class.new(scope_type: "repository", scope_id: 1, task_key: "default")

    expect(record).to be_valid
    expect(record.candidates).to eq([])
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

  it "accepts an ordered multi-candidate fallback chain across known providers" do
    record = rule(candidates: [
      { "provider" => "claude", "model" => "claude-sonnet-4-6", "effort_level" => "high" },
      { "provider" => "codex" }
    ])

    expect(record).to be_valid
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
