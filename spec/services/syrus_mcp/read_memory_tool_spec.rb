require "rails_helper"

RSpec.describe SyrusMcp::ReadMemoryTool do
  let(:run) { Factories.job.initial_run }

  def call(id:, context: { run_id: run.id })
    described_class.call(id: id, server_context: context)
  end

  def payload_from(response)
    JSON.parse(response.content.first[:text])
  end

  describe ".call" do
    it "reads a memory owned by the current job user" do
      memory = ChatMemory.create!(
        user: run.job.user,
        kind: "project_fact",
        scope: "repository",
        scope_id: run.job.repository_id,
        content: "The deploy pipeline runs on Buildkite."
      )

      response = call(id: memory.id)

      expect(response).not_to be_error
      expect(payload_from(response)).to eq(
        "kind" => "project_fact",
        "scope" => "repository",
        "content" => "The deploy pipeline runs on Buildkite.",
        "created_at" => memory.created_at.iso8601
      )
    end

    it "returns a tool error for an unknown memory id" do
      response = call(id: 0)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("memory not found: 0")
    end

    it "rejects memories owned by another user" do
      other_repository = Factories.repository(user: Factories.user)
      memory = ChatMemory.create!(
        user: other_repository.user,
        kind: "reference",
        scope: "repository",
        scope_id: other_repository.id,
        content: "Private context from another user."
      )

      response = call(id: memory.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("memory not found: #{memory.id}")
    end
  end

  describe "schema surface" do
    it "requires a memory id" do
      expect(described_class.tool_name).to eq("read_memory")
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to eq(%w[id])
      expect(schema.dig(:properties, :id, :type)).to eq("integer")
    end
  end
end
