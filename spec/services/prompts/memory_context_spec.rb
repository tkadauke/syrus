require "rails_helper"

RSpec.describe Prompts::MemoryContext do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def create_memory(kind:, content:, scope: "repository", scope_id: repository.id, memory_user: user, published: false)
    ChatMemory.create!(
      user: memory_user,
      kind: kind,
      scope: scope,
      scope_id: scope_id,
      content: content,
      published: published
    )
  end

  it "returns an empty string when no memories are visible" do
    output = described_class.new(user: user, repository_ids: [ repository.id ]).to_s

    expect(output).to eq("")
  end

  it "renders feedback and user preferences as full-content memory blocks" do
    feedback = create_memory(kind: "feedback", content: "Prefer smaller commits.")
    user_pref = create_memory(kind: "user_pref", content: "Use concise PR descriptions.", scope: "global", scope_id: nil)

    output = described_class.new(user: user, repository_ids: [ repository.id ]).to_s

    expect(output).to include("# Memory: feedback (#{feedback.id})\nPrefer smaller commits.")
    expect(output).to include("# Memory: user_pref (#{user_pref.id})\nUse concise PR descriptions.")
    expect(output).not_to include("# Saved context")
  end

  it "renders project facts, decisions, and references as a compact index" do
    fact = create_memory(kind: "project_fact", content: "Rails handles the web UI.")
    decision = create_memory(kind: "decision", content: "Use Solid Queue for background jobs.")
    reference = create_memory(kind: "reference", content: "See docs/current-user-scopes.md.")

    output = described_class.new(user: user, repository_ids: [ repository.id ]).to_s

    expect(output).to include("# Saved context (call read_memory(id) for full content)")
    expect(output).to include("- [#{fact.id}] project_fact: Rails handles the web UI.")
    expect(output).to include("- [#{decision.id}] decision: Use Solid Queue for background jobs.")
    expect(output).to include("- [#{reference.id}] reference: See docs/current-user-scopes.md.")
    expect(output).not_to include("# Memory:")
  end

  it "renders full-content memories before the compact index" do
    fact = create_memory(kind: "project_fact", content: "This repo uses Rails.")
    feedback = create_memory(kind: "feedback", content: "Keep test plans actionable.")

    output = described_class.new(user: user, repository_ids: [ repository.id ]).to_s

    expect(output.index("# Memory: feedback (#{feedback.id})")).to be < output.index("# Saved context")
    expect(output).to include("- [#{fact.id}] project_fact: This repo uses Rails.")
  end

  it "ranks high-confidence memories before low-confidence ones" do
    ChatMemory.create!(user: user, kind: "feedback", scope: "repository", scope_id: repository.id, content: "Low confidence.", confidence: 0.3)
    ChatMemory.create!(user: user, kind: "feedback", scope: "repository", scope_id: repository.id, content: "High confidence.", confidence: 0.9)

    output = described_class.new(user: user, repository_ids: [ repository.id ]).to_s

    expect(output.index("High confidence.")).to be < output.index("Low confidence.")
  end

  it "ranks repository-scoped memories above global ones" do
    ChatMemory.create!(user: user, kind: "feedback", scope: "global", content: "Global feedback.")
    ChatMemory.create!(user: user, kind: "feedback", scope: "repository", scope_id: repository.id, content: "Repository feedback.")

    output = described_class.new(user: user, repository_ids: [ repository.id ]).to_s

    expect(output.index("Repository feedback.")).to be < output.index("Global feedback.")
  end

  it "uses safe byte truncation for compact index content" do
    memory = create_memory(kind: "reference", content: "#{"a" * 119}€tail")

    output = described_class.new(user: user, repository_ids: [ repository.id ]).to_s
    compact_line = output.lines.find { |line| line.include?("[#{memory.id}]") }

    expect(compact_line).to be_valid_encoding
    expect(compact_line).to include("#{"a" * 119}")
    expect(compact_line).not_to include("€tail")
  end
end
