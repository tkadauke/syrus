require "rails_helper"

RSpec.describe SyrusMcp::WriteMemoryTool do
  let(:run) { Factories.job.initial_run }
  let(:user) { run.job.user }
  let(:repository) { run.job.repository }

  def call(content:, kind:, context: { run_id: run.id })
    described_class.call(content: content, kind: kind, server_context: context)
  end

  describe ".call" do
    it "creates a repository-scoped memory for the job's repository" do
      response = call(content: "Use snake_case for all methods.", kind: "feedback")

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to include(
        "scope"    => "repository",
        "scope_id" => repository.id,
        "content"  => "Use snake_case for all methods.",
        "kind"     => "feedback"
      )
    end

    it "sets author, source_type, and source_id from the agent run context" do
      response = call(content: "Deploy uses Buildkite.", kind: "project_fact")

      payload = JSON.parse(response.content.first[:text])
      expect(payload).to include(
        "author"      => "agent",
        "source_type" => "run",
        "source_id"   => run.id
      )
    end

    it "persists the memory with the correct attributes" do
      call(content: "The deploy pipeline uses Buildkite.", kind: "project_fact")

      memory = ChatMemory.last
      expect(memory.scope).to eq("repository")
      expect(memory.scope_id).to eq(repository.id)
      expect(memory.author).to eq("agent")
      expect(memory.source_type).to eq("run")
      expect(memory.source_id).to eq(run.id)
    end

    it "always writes to the job's repository scope, never global" do
      call(content: "Some knowledge.", kind: "reference")

      memory = ChatMemory.last
      expect(memory.scope).to eq("repository")
      expect(memory.scope_id).to eq(repository.id)
      expect(memory.global?).to be false
    end

    it "returns an error for empty content" do
      response = call(content: "  ", kind: "feedback")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("content is required")
    end

    it "returns an error for an invalid kind" do
      response = call(content: "Some content.", kind: "not_a_kind")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("kind must be one of")
    end

    it "returns an error for an invalid run context" do
      response = call(content: "Some content.", kind: "feedback", context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe "schema surface" do
    it "requires content and kind" do
      expect(described_class.tool_name).to eq("write_memory")
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to match_array(%w[content kind])
    end
  end
end
