require "rails_helper"

RSpec.describe ChatMemory do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner) }

  def build_memory(**attrs)
    described_class.new({
      user: owner,
      kind: "project_fact",
      scope: "repository",
      scope_id: repo.id,
      content: "The repo uses Rails."
    }.merge(attrs))
  end

  it "accepts valid repository-scoped memories" do
    memory = build_memory
    expect(memory).to be_valid
  end

  it "validates kind and scope enums" do
    memory = build_memory(kind: "habit", scope: "workspace")

    expect(memory).not_to be_valid
    expect(memory.errors[:kind]).to be_present
    expect(memory.errors[:scope]).to be_present
  end

  it "requires repository-scoped memories to have a scope_id" do
    memory = build_memory(scope: "repository", scope_id: nil)

    expect(memory).not_to be_valid
    expect(memory.errors[:scope_id]).to include("must be present for repository scope")
  end

  it "requires global memories to have no scope_id" do
    memory = build_memory(scope: "global", scope_id: repo.id)

    expect(memory).not_to be_valid
    expect(memory.errors[:scope_id]).to include("must be nil for global scope")
  end

  it "limits content length" do
    memory = build_memory(content: "a" * (described_class::CONTENT_MAX_LENGTH + 1))

    expect(memory).not_to be_valid
    expect(memory.errors[:content]).to be_present
  end

  it "only allows published memories for repository scope" do
    memory = build_memory(scope: "global", scope_id: nil, published: true)

    expect(memory).not_to be_valid
    expect(memory.errors[:published]).to include("can only be true for repository scope")
  end

  describe ".visible_to" do
    let(:other_user) { Factories.user }
    let(:other_repo) { Factories.repository(user: owner) }

    it "returns own global, own repo, and published repo memories from other users" do
      own_global = described_class.create!(
        user: owner,
        kind: "user_pref",
        scope: "global",
        content: "Use concise responses."
      )
      own_repo = described_class.create!(
        user: owner,
        kind: "project_fact",
        scope: "repository",
        scope_id: repo.id,
        content: "This repo uses Rails."
      )
      published_other = described_class.create!(
        user: other_user,
        kind: "reference",
        scope: "repository",
        scope_id: repo.id,
        content: "Shared runbook.",
        published: true
      )
      unpublished_other = described_class.create!(
        user: other_user,
        kind: "decision",
        scope: "repository",
        scope_id: repo.id,
        content: "Private draft."
      )
      other_repo_memory = described_class.create!(
        user: owner,
        kind: "feedback",
        scope: "repository",
        scope_id: other_repo.id,
        content: "Different repo."
      )

      visible = described_class.visible_to(owner, repo)

      expect(visible).to include(own_global, own_repo, published_other)
      expect(visible).not_to include(unpublished_other, other_repo_memory)
    end
  end
end
