require "rails_helper"

RSpec.describe Mcp::Tools::WriteMemoryTool do
  let(:run)        { Factories.job.initial_run }
  let(:repository) { run.job.repository }

  def run_context = { run_id: run.id }
  def chat_context(session) = { chat_session: session }

  describe "schema surface" do
    it "has tool_name write_memory" do
      expect(described_class.tool_name).to eq("write_memory")
    end

    it "requires content and kind; scope and scope_id are optional" do
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to match_array(%w[content kind])
      expect(schema.dig(:properties, :scope)).to be_present
      expect(schema.dig(:properties, :scope_id)).to be_present
    end
  end

  describe ".call from a workflow run context" do
    it "creates a repository-scoped memory for the job's repository" do
      response = described_class.call(content: "Use snake_case.", kind: "feedback", server_context: run_context)

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text], symbolize_names: true)
      expect(payload.dig(:memory, :scope)).to eq("repository")
      expect(payload.dig(:memory, :scope_id)).to eq(repository.id)
    end

    it "sets author, source_type, and source_id from the run context" do
      described_class.call(content: "Deploy runs on Buildkite.", kind: "project_fact", server_context: run_context)

      memory = ChatMemory.last
      expect(memory).to have_attributes(author: "agent", source_type: "run", source_id: run.id)
    end

    it "persists to the job's repository when scope is omitted" do
      described_class.call(content: "Some knowledge.", kind: "reference", server_context: run_context)

      expect(ChatMemory.last.scope).to eq("repository")
      expect(ChatMemory.last.scope_id).to eq(repository.id)
    end

    it "rejects global scope because it is not in allowed_memory_scopes for runs" do
      response = described_class.call(content: "x", kind: "feedback", scope: "global", server_context: run_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("scope must be one of")
    end

    it "returns an error for empty content" do
      response = described_class.call(content: "  ", kind: "feedback", server_context: run_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("content is required")
    end

    it "returns an error for an invalid kind" do
      response = described_class.call(content: "x", kind: "not_a_kind", server_context: run_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("kind must be one of")
    end

    it "returns an error for an invalid run context" do
      response = described_class.call(content: "x", kind: "feedback", server_context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe ".call from a chat session context" do
    let(:chat_user)    { Factories.user }
    let(:chat_repo)    { Factories.repository(user: chat_user) }
    let(:chat_session) { ChatSession.create!(user: chat_user, repository: chat_repo) }

    it "creates a global memory when scope is global" do
      response = described_class.call(content: "Prefer concise replies.", kind: "user_pref",
                                      scope: "global", server_context: chat_context(chat_session))

      expect(response).not_to be_error
      memory = ChatMemory.find(JSON.parse(response.content.first[:text], symbolize_names: true)[:id])
      expect(memory).to have_attributes(scope: "global", scope_id: nil, user: chat_user)
    end

    it "creates a repository-scoped memory for an owned repository" do
      response = described_class.call(content: "CI uses Buildkite.", kind: "project_fact",
                                      scope: "repository", scope_id: chat_repo.id,
                                      server_context: chat_context(chat_session))

      expect(response).not_to be_error
      memory = ChatMemory.find(JSON.parse(response.content.first[:text], symbolize_names: true)[:id])
      expect(memory.scope_id).to eq(chat_repo.id)
    end

    it "rejects a scope_id pointing to a repository the user doesn't own" do
      other_repo = Factories.repository(user: Factories.user)

      response = described_class.call(content: "x", kind: "reference", scope: "repository",
                                      scope_id: other_repo.id, server_context: chat_context(chat_session))

      expect(response).to be_error
      expect(response.content.first[:text]).to include("scope_id must be a repository id owned by the current user")
    end

    it "rejects a scope_id when scope is global" do
      response = described_class.call(content: "x", kind: "reference", scope: "global",
                                      scope_id: chat_repo.id, server_context: chat_context(chat_session))

      expect(response).to be_error
      expect(response.content.first[:text]).to include("scope_id must be omitted")
    end

    it "does not set author or source fields (user-initiated)" do
      described_class.call(content: "x", kind: "feedback", scope: "global",
                           server_context: chat_context(chat_session))

      memory = ChatMemory.last
      expect(memory.author).to be_nil
      expect(memory.source_type).to be_nil
      expect(memory.source_id).to be_nil
    end
  end
end
