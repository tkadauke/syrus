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
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to include(
        "id"         => memory.id,
        "kind"       => "project_fact",
        "scope"      => "repository",
        "scope_id"   => memory.scope_id,
        "content"    => "The deploy pipeline runs on Buildkite.",
        "created_at" => memory.created_at.iso8601
      )
    end

    it "includes provenance fields in the payload" do
      memory = ChatMemory.create!(
        user: run.job.user,
        kind: "feedback",
        scope: "global",
        content: "Always prefer short functions.",
        source_type: "job",
        source_id: run.job_id,
        author: "agent",
        confidence: 0.8,
        visibility: "private"
      )

      response = call(id: memory.id)

      payload = JSON.parse(response.content.first[:text])
      expect(payload).to include(
        "source_type" => "job",
        "source_id"   => run.job_id,
        "author"      => "agent",
        "confidence"  => be_within(0.01).of(0.8),
        "visibility"  => "private"
      )
      expect(payload["last_verified_at"]).to be_nil
      expect(payload["expires_at"]).to be_nil
    end

    it "returns a tool error for an unknown memory id" do
      response = call(id: 0)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end

    it "rejects memories owned by another user" do
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
    it "requires a memory id" do
      expect(described_class.tool_name).to eq("read_memory")
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to eq(%w[id])
      expect(schema.dig(:properties, :id, :type)).to eq("integer")
    end
  end
end
