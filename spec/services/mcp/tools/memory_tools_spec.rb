require "rails_helper"

# Integration-level tests for the shared search/list tools across both
# surfaces, plus end-to-end tests that verify the full chat-surface
# tool set (write/read/delete/publish/unpublish) via an MCP server.
RSpec.describe "Mcp::Tools shared memory tools" do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:run)        { Factories.job(repository: repository, user: user).initial_run }

  def run_context   = { run_id: run.id }
  def chat_context(session) = { chat_session: session }

  def create_repo_memory(owner: user, repo: repository, content: "Default memory.", **attrs)
    ChatMemory.create!({
      user: owner, kind: "project_fact", scope: "repository",
      scope_id: repo.id, content: content
    }.merge(attrs))
  end

  # --- SearchMemoriesTool ---

  describe Mcp::Tools::SearchMemoriesTool do
    describe "schema surface" do
      it "has tool_name search_memories and requires query" do
        expect(described_class.tool_name).to eq("search_memories")
        schema = described_class.input_schema_value.to_h
        expect(schema[:required]).to eq(%w[query])
      end
    end

    context "run surface" do
      it "finds memories matching the query within the job's repository" do
        create_repo_memory(content: "Alpha deployment notes.")
        create_repo_memory(content: "Beta release process.")

        response = described_class.call(query: "alpha", server_context: run_context)

        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }
        expect(ids.size).to eq(1)
        expect(ChatMemory.find(ids.first).content).to include("Alpha")
      end

      it "includes published memories from other users in the same repository" do
        other_user = Factories.user
        shared = create_repo_memory(owner: other_user, content: "shared alpha hint", published: true)

        response = described_class.call(query: "alpha", server_context: run_context)
        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }

        expect(ids).to include(shared.id)
      end

      it "does not include memories from other repositories" do
        other_repo   = Factories.repository(user: user)
        other_memory = create_repo_memory(repo: other_repo, content: "alpha other repo")

        response = described_class.call(query: "alpha", server_context: run_context)
        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }

        expect(ids).not_to include(other_memory.id)
      end

      it "returns an error for an empty query" do
        response = described_class.call(query: "  ", server_context: run_context)
        expect(response).to be_error
      end

      it "rejects an invalid kind filter" do
        response = described_class.call(query: "x", kind: "bad_kind", server_context: run_context)
        expect(response).to be_error
      end
    end

    context "chat surface" do
      let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

      it "searches visible memories including global scope" do
        global = ChatMemory.create!(user: user, kind: "user_pref", scope: "global", scope_id: nil,
                                    content: "alpha global preference")

        response = described_class.call(query: "alpha", server_context: chat_context(chat_session))
        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }

        expect(ids).to include(global.id)
      end

      it "filters by scope when scope is provided" do
        global = ChatMemory.create!(user: user, kind: "user_pref", scope: "global", scope_id: nil, content: "alpha global")
        repo_m = create_repo_memory(content: "alpha repo")

        response = described_class.call(query: "alpha", scope: "global", server_context: chat_context(chat_session))
        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }

        expect(ids).to include(global.id)
        expect(ids).not_to include(repo_m.id)
      end
    end
  end

  # --- ListMemoriesTool ---

  describe Mcp::Tools::ListMemoriesTool do
    describe "schema surface" do
      it "has tool_name list_memories with no required fields" do
        expect(described_class.tool_name).to eq("list_memories")
        schema = described_class.input_schema_value.to_h
        expect(schema[:required]).to be_blank
      end
    end

    context "run surface" do
      it "lists active memories within the job's repository" do
        m1 = create_repo_memory(content: "First note.")
        m2 = create_repo_memory(content: "Second note.")
        create_repo_memory(content: "Deleted.").tap { |m| m.update!(deleted_at: Time.current) }

        response = described_class.call(server_context: run_context)
        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }

        expect(ids).to include(m1.id, m2.id)
        expect(ids.size).to eq(2)
      end

      it "filters by kind" do
        feedback = create_repo_memory(kind: "feedback", content: "Feedback memory.")
        _fact    = create_repo_memory(kind: "project_fact", content: "Fact memory.")

        response = described_class.call(kind: "feedback", server_context: run_context)
        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }

        expect(ids).to eq([ feedback.id ])
      end

      it "returns an error for an invalid scope" do
        response = described_class.call(scope: "team", server_context: run_context)
        expect(response).to be_error
        expect(response.content.first[:text]).to include("scope must be one of")
      end
    end

    context "chat surface" do
      let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

      it "lists memories visible to the chat session" do
        global = ChatMemory.create!(user: user, kind: "user_pref", scope: "global", scope_id: nil, content: "Global pref.")
        repo_m = create_repo_memory(content: "Repo fact.")

        response = described_class.call(server_context: chat_context(chat_session))
        ids = JSON.parse(response.content.first[:text], symbolize_names: true)[:memories].map { |m| m[:id] }

        expect(ids).to include(global.id, repo_m.id)
      end
    end
  end

  # --- Full chat sidecar MCP server end-to-end ---

  describe "chat surface full tool set via MCP server" do
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

    def server
      MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [
          Mcp::Tools::WriteMemoryTool,
          Mcp::Tools::ReadMemoryTool,
          Mcp::Tools::SearchMemoriesTool,
          Mcp::Tools::ListMemoriesTool,
          Mcp::Tools::DeleteMemoryTool,
          SyrusChatMcp::PublishMemoryTool,
          SyrusChatMcp::UnpublishMemoryTool
        ],
        server_context: { chat_session: chat_session }
      )
    end

    def call_tool(name, arguments = {})
      raw = server.handle_json({
        jsonrpc: "2.0", id: 1, method: "tools/call",
        params:  { name: name, arguments: arguments }
      }.to_json)
      JSON.parse(raw, symbolize_names: true)
    end

    def payload(response) = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)

    it "writes a global memory" do
      response = call_tool("write_memory", content: "Prefer concise replies.", kind: "user_pref", scope: "global")

      memory = ChatMemory.find(payload(response)[:id])
      expect(memory).to have_attributes(user: user, scope: "global", scope_id: nil)
    end

    it "writes a repository-scoped memory only for owned repos" do
      good = call_tool("write_memory", content: "CI uses Buildkite.", kind: "project_fact",
                       scope: "repository", scope_id: repository.id)
      other_repo = Factories.repository(user: Factories.user)
      bad = call_tool("write_memory", content: "x", kind: "project_fact",
                      scope: "repository", scope_id: other_repo.id)

      expect(ChatMemory.find(payload(good)[:id]).scope_id).to eq(repository.id)
      expect(bad.dig(:result, :isError)).to be true
    end

    it "reads an owned memory by id" do
      m = ChatMemory.create!(user: user, kind: "feedback", scope: "global", content: "A note.")
      response = call_tool("read_memory", id: m.id)
      expect(payload(response).dig(:memory, :id)).to eq(m.id)
    end

    it "lists visible memories" do
      global = ChatMemory.create!(user: user, kind: "user_pref", scope: "global", scope_id: nil, content: "Pref.")
      repo_m = create_repo_memory(content: "Repo fact.")

      response = call_tool("list_memories")
      ids = payload(response)[:memories].map { |m| m[:id] }
      expect(ids).to include(global.id, repo_m.id)
    end

    it "searches memories by content" do
      create_repo_memory(content: "Alpha deployment notes.")
      response = call_tool("search_memories", query: "alpha")
      ids = payload(response)[:memories].map { |m| m[:id] }
      expect(ids.size).to be >= 1
    end

    it "deletes only memories owned by the caller" do
      owned = create_repo_memory(content: "To delete.")
      other = create_repo_memory(owner: Factories.user, content: "Others.", published: true)

      good_response = call_tool("delete_memory", id: owned.id)
      bad_response  = call_tool("delete_memory", id: other.id)

      expect(payload(good_response)).to include(id: owned.id, deleted: true)
      expect(bad_response.dig(:result, :isError)).to be true
    end

    it "publishes and unpublishes owned repository memories" do
      memory = create_repo_memory(content: "Publishable.")

      publish_response = call_tool("publish_memory", memory_id: memory.id)
      expect(payload(publish_response).dig(:memory, :published)).to be true
      expect(memory.reload).to be_published

      unpublish_response = call_tool("unpublish_memory", memory_id: memory.id)
      expect(payload(unpublish_response).dig(:memory, :published)).to be false
    end

    it "asserts no tool class name duplication between syrus_mcp and syrus_chat_mcp" do
      run_class_names  = Dir[Rails.root.join("app/services/syrus_mcp/*_tool.rb")]
        .map { |path| File.basename(path, ".rb") }
      chat_class_names = Dir[Rails.root.join("app/services/syrus_chat_mcp/*_tool.rb")]
        .map { |path| File.basename(path, ".rb") }
      shared_class_names = Dir[Rails.root.join("app/services/mcp/tools/*_tool.rb")]
        .map { |path| File.basename(path, ".rb") }

      expect(run_class_names & chat_class_names).to be_empty,
        "Duplicate tool file basenames found between syrus_mcp/ and syrus_chat_mcp/: " \
        "#{(run_class_names & chat_class_names).inspect}"

      expect(run_class_names & shared_class_names).to be_empty,
        "Duplicate tool file basenames found between syrus_mcp/ and mcp/tools/: " \
        "#{(run_class_names & shared_class_names).inspect}"

      expect(chat_class_names & shared_class_names).to be_empty,
        "Duplicate tool file basenames found between syrus_chat_mcp/ and mcp/tools/: " \
        "#{(chat_class_names & shared_class_names).inspect}"
    end
  end
end
