require "rails_helper"

RSpec.describe AgentMemory::Store do
  describe ".selected_review_memories" do
    let(:owner) { Factories.user }
    let(:other_user) { Factories.user }
    let(:repository) { Factories.repository(user: owner) }

    def memory(user: owner, repository_id: repository.id, published: true, content: "Selected policy")
      AgentMemory::Entry.create!(user:, kind: "project_fact", scope: "repository", scope_id: repository_id,
        published:, content:)
    end

    it "returns only explicitly selected published repository memories owned by the reviewer owner" do
      selected = memory
      memory(content: "Eligible but unused")
      private_memory = memory(published: false, content: "Private")
      foreign_memory = memory(user: other_user, content: "Someone else's")
      other_repository_memory = memory(repository_id: Factories.repository(user: owner).id, content: "Other repository")

      result = described_class.selected_review_memories(user: owner, repository_id: repository.id,
        ids: [ selected.id, private_memory.id, foreign_memory.id, other_repository_memory.id ])

      expect(result).to contain_exactly(id: selected.id, revision: selected.updated_at.iso8601,
        content: "Selected policy")
    end
  end
end
