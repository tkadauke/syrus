require "rails_helper"

RSpec.describe Mcp::Tools::ReadMemoryTool do
  let(:run)  { Factories.job.initial_run }
  let(:user) { run.job.user }

  def run_context   = { run_id: run.id }
  def chat_context(session) = { chat_session: session }

  def create_memory(owner: user, **attrs)
    ChatMemory.create!({
      user:    owner,
      kind:    "feedback",
      scope:   "global",
      content: "Always prefer short functions."
    }.merge(attrs))
  end

  describe "schema surface" do
    it "has tool_name read_memory" do
      expect(described_class.tool_name).to eq("read_memory")
    end

    it "requires id as an integer" do
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to eq(%w[id])
      expect(schema.dig(:properties, :id, :type)).to eq("integer")
    end
  end

  describe ".call from a workflow run context" do
    it "reads a memory owned by the job user" do
      memory = create_memory(kind: "project_fact", scope: "repository", scope_id: run.job.repository_id)

      response = described_class.call(id: memory.id, server_context: run_context)

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text], symbolize_names: true)
      expect(payload.dig(:memory, :id)).to eq(memory.id)
      expect(payload.dig(:memory, :kind)).to eq("project_fact")
      expect(payload.dig(:memory, :content)).to eq(memory.content)
    end

    it "includes provenance fields" do
      memory = create_memory(source_type: "job", source_id: run.job_id, author: "agent", confidence: 0.9)

      response = described_class.call(id: memory.id, server_context: run_context)

      payload = JSON.parse(response.content.first[:text], symbolize_names: true)
      expect(payload.dig(:memory, :source_type)).to eq("job")
      expect(payload.dig(:memory, :author)).to eq("agent")
    end

    it "reads globally-scoped memories owned by the user" do
      global = create_memory(scope: "global", scope_id: nil)

      response = described_class.call(id: global.id, server_context: run_context)

      expect(response).not_to be_error
    end

    it "returns an error for an unknown id" do
      response = described_class.call(id: 0, server_context: run_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "rejects memories owned by another user" do
      other_memory = create_memory(owner: Factories.user)

      response = described_class.call(id: other_memory.id, server_context: run_context)

      expect(response).to be_error
    end

    it "rejects a soft-deleted memory" do
      memory = create_memory
      memory.update!(deleted_at: Time.current)

      response = described_class.call(id: memory.id, server_context: run_context)

      expect(response).to be_error
    end

    it "returns an error for an invalid run context" do
      response = described_class.call(id: 1, server_context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe ".call from a chat session context" do
    let(:chat_user)    { Factories.user }
    let(:chat_repo)    { Factories.repository(user: chat_user) }
    let(:chat_session) { ChatSession.create!(user: chat_user, repository: chat_repo) }

    it "reads an owned memory" do
      memory = ChatMemory.create!(user: chat_user, kind: "feedback", scope: "global", content: "Nice.")

      response = described_class.call(id: memory.id, server_context: chat_context(chat_session))

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text], symbolize_names: true)
      expect(payload.dig(:memory, :id)).to eq(memory.id)
    end

    it "reads published memories from other users in an attached repository" do
      other_user = Factories.user
      published  = ChatMemory.create!(user: other_user, kind: "reference", scope: "repository",
                                      scope_id: chat_repo.id, content: "Shared fact.", published: true)

      response = described_class.call(id: published.id, server_context: chat_context(chat_session))

      expect(response).not_to be_error
    end

    it "rejects unpublished memories owned by other users" do
      other_user = Factories.user
      private_m  = ChatMemory.create!(user: other_user, kind: "reference", scope: "repository",
                                      scope_id: chat_repo.id, content: "Private.")

      response = described_class.call(id: private_m.id, server_context: chat_context(chat_session))

      expect(response).to be_error
    end

    it "does not read deleted owned memories" do
      memory = ChatMemory.create!(user: chat_user, kind: "feedback", scope: "global", content: "Old.")
      memory.soft_delete_by!(chat_user)

      response = described_class.call(id: memory.id, server_context: chat_context(chat_session))

      expect(response).to be_error
    end
  end
end
