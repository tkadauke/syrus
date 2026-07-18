require "rails_helper"

RSpec.describe SyrusMcp::DeleteMemoryTool do
  let(:run) { Factories.job.initial_run }
  let(:user) { run.job.user }
  let(:repository) { run.job.repository }

  def create_memory(owner: user, repo: repository, **attrs)
    ChatMemory.create!({
      user: owner,
      kind: "feedback",
      scope: "repository",
      scope_id: repo.id,
      content: "Always write tests first."
    }.merge(attrs))
  end

  def call(memory_id:, context: { run_id: run.id })
    described_class.call(memory_id: memory_id, server_context: context)
  end

  describe ".call" do
    it "soft-deletes a memory owned by the job user in the job repository" do
      memory = create_memory

      response = call(memory_id: memory.id)

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to include("id" => memory.id, "deleted" => true)
      expect(memory.reload.deleted_at).not_to be_nil
    end

    it "emits an audit event with actor_run_id" do
      memory = create_memory

      expect {
        call(memory_id: memory.id)
      }.to change(ChatMemoryAuditEvent, :count).by(1)

      event = ChatMemoryAuditEvent.where(chat_memory_id: memory.id, event_type: "deleted").last
      expect(event.actor_kind).to eq("agent")
      expect(event.actor_run_id).to eq(run.id)
      expect(event.actor_user_id).to be_nil
    end

    it "rejects a memory from a different repository (cross-repo)" do
      other_repo = Factories.repository(user: user)
      cross_repo_memory = create_memory(repo: other_repo)

      response = call(memory_id: cross_repo_memory.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "rejects a memory owned by another user" do
      other_memory = create_memory(owner: Factories.user)

      response = call(memory_id: other_memory.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "rejects an already soft-deleted memory" do
      memory = create_memory
      memory.update!(deleted_at: Time.current)

      response = call(memory_id: memory.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "returns an error for an invalid run context" do
      memory = create_memory

      response = call(memory_id: memory.id, context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe "schema surface" do
    it "requires memory_id as an integer" do
      expect(described_class.tool_name).to eq("delete_memory")
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to eq(%w[memory_id])
      expect(schema.dig(:properties, :memory_id, :type)).to eq("integer")
    end
  end
end
