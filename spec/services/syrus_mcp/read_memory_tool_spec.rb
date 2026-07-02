require "rails_helper"

RSpec.describe SyrusMcp::ReadMemoryTool do
  let(:run) { Factories.job.initial_run }
  let(:user) { run.job.user }

  def create_memory(owner: user, **attrs)
    ChatMemory.create!({
      user: owner,
      kind: "feedback",
      scope: "global",
      content: "Always prefer short functions."
    }.merge(attrs))
  end

  def call(id:, context: { run_id: run.id })
    described_class.call(id: id, server_context: context)
  end

  describe ".call" do
    it "returns kind, scope, content, and created_at for a memory owned by the job's user" do
      memory = create_memory

      response = call(id: memory.id)

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to include(
        "id"      => memory.id,
        "kind"    => memory.kind,
        "scope"   => memory.scope,
        "content" => memory.content
      )
      expect(payload["created_at"]).to be_present
    end

    it "returns an error for a memory id that does not exist" do
      response = call(id: 0)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "rejects a memory belonging to another user" do
      other_memory = create_memory(owner: Factories.user)

      response = call(id: other_memory.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "rejects a soft-deleted memory" do
      memory = create_memory
      memory.update!(deleted_at: Time.current)

      response = call(id: memory.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "returns an error for an invalid run context" do
      response = call(id: 1, context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe "schema surface" do
    it "is named read_memory with a single required integer id property" do
      expect(described_class.tool_name).to eq("read_memory")
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to eq(%w[id])
      expect(schema[:properties].keys).to eq([ :id ])
    end
  end
end
