require "rails_helper"

RSpec.describe Mcp::Tools::DeleteMemoryTool do
  let(:run)        { Factories.job.initial_run }
  let(:user)       { run.job.user }
  let(:repository) { run.job.repository }

  def run_context = { run_id: run.id }
  def chat_context(session) = { chat_session: session }

  def create_memory(owner: user, repo: repository, **attrs)
    ChatMemory.create!({
      user: owner, kind: "feedback", scope: "repository",
      scope_id: repo.id, content: "Always write tests first."
    }.merge(attrs))
  end

  describe "schema surface" do
    it "has tool_name delete_memory" do
      expect(described_class.tool_name).to eq("delete_memory")
    end

    it "requires id as an integer" do
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to eq(%w[id])
      expect(schema.dig(:properties, :id, :type)).to eq("integer")
    end
  end

  describe ".call from a workflow run context" do
    it "soft-deletes a repository memory owned by the job user" do
      memory = create_memory

      response = described_class.call(id: memory.id, server_context: run_context)

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text], symbolize_names: true)
      expect(payload).to include(id: memory.id, deleted: true)
      expect(memory.reload.deleted_at).not_to be_nil
    end

    it "emits an audit event with actor_run_id" do
      memory = create_memory

      expect {
        described_class.call(id: memory.id, server_context: run_context)
      }.to change(ChatMemoryAuditEvent, :count).by(1)

      event = ChatMemoryAuditEvent.where(chat_memory_id: memory.id, event_type: "deleted").last
      expect(event.actor_kind).to eq("agent")
      expect(event.actor_run_id).to eq(run.id)
    end

    it "rejects a memory from a different repository" do
      other_repo = Factories.repository(user: user)
      cross_repo = create_memory(repo: other_repo)

      response = described_class.call(id: cross_repo.id, server_context: run_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "rejects a memory owned by another user" do
      other_memory = create_memory(owner: Factories.user)

      response = described_class.call(id: other_memory.id, server_context: run_context)

      expect(response).to be_error
    end

    it "rejects an already soft-deleted memory" do
      memory = create_memory
      memory.update!(deleted_at: Time.current)

      response = described_class.call(id: memory.id, server_context: run_context)

      expect(response).to be_error
    end

    it "returns an error for an invalid run context" do
      memory = create_memory

      response = described_class.call(id: memory.id, server_context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe ".call from a chat session context" do
    let(:chat_user)    { Factories.user }
    let(:chat_repo)    { Factories.repository(user: chat_user) }
    let(:chat_session) { ChatSession.create!(user: chat_user, repository: chat_repo) }

    it "soft-deletes a memory owned by the chat user" do
      owned = ChatMemory.create!(user: chat_user, kind: "feedback", scope: "repository",
                                 scope_id: chat_repo.id, content: "Write tests.")

      response = described_class.call(id: owned.id, server_context: chat_context(chat_session))

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text], symbolize_names: true)
      expect(payload).to include(id: owned.id, deleted: true)
      expect(owned.reload.deleted_by_user).to eq(chat_user)
    end

    it "rejects deletion of another user's memory" do
      other = ChatMemory.create!(user: Factories.user, kind: "feedback", scope: "repository",
                                  scope_id: chat_repo.id, content: "Not yours.", published: true)

      response = described_class.call(id: other.id, server_context: chat_context(chat_session))

      expect(response).to be_error
    end

    it "allows deleting a memory in a cross-repo (chat surface only checks ownership)" do
      other_repo = Factories.repository(user: chat_user)
      owned = ChatMemory.create!(user: chat_user, kind: "feedback", scope: "repository",
                                 scope_id: other_repo.id, content: "In other repo.")

      response = described_class.call(id: owned.id, server_context: chat_context(chat_session))

      expect(response).not_to be_error
    end
  end
end
