require "rails_helper"

RSpec.describe "SyrusChatMcp memory tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::WriteMemoryTool,
        SyrusChatMcp::ReadMemoryTool,
        SyrusChatMcp::SearchMemoriesTool,
        SyrusChatMcp::ListMemoriesTool,
        SyrusChatMcp::DeleteMemoryTool,
        SyrusChatMcp::PublishMemoryTool,
        SyrusChatMcp::UnpublishMemoryTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def error_text(response)
    response.dig(:result, :content, 0, :text) || response.dig(:error, :message)
  end

  def tool_error?(response)
    response.dig(:result, :isError) == true || response[:error].present?
  end

  def create_memory(**attrs)
    ChatMemory.create!({
      user: user,
      kind: "project_fact",
      scope: "repository",
      scope_id: repository.id,
      content: "The repo uses Rails."
    }.merge(attrs))
  end

  it "writes a global memory directly without a pending action" do
    response = call_tool("write_memory", content: "Prefer concise replies.", kind: "user_pref", scope: "global")
    memory = ChatMemory.find(payload(response)[:id])

    expect(memory).to have_attributes(user: user, content: "Prefer concise replies.", kind: "user_pref", scope: "global", scope_id: nil)
    expect(chat_session.pending_actions).to be_empty
  end

  it "writes repository-scoped memories only for repositories owned by the caller" do
    other_repo = Factories.repository(user: Factories.user)

    response = call_tool(
      "write_memory",
      content: "CI uses Buildkite.",
      kind: "project_fact",
      scope: "repository",
      scope_id: repository.id
    )
    invalid_response = call_tool(
      "write_memory",
      content: "Private elsewhere.",
      kind: "project_fact",
      scope: "repository",
      scope_id: other_repo.id
    )

    expect(ChatMemory.find(payload(response)[:id]).scope_id).to eq(repository.id)
    expect(invalid_response.dig(:result, :isError)).to be true
    expect(error_text(invalid_response)).to include("scope_id must be a repository id owned by the current user")
  end

  it "rejects invalid write kind and scope combinations" do
    bad_kind = call_tool("write_memory", content: "x", kind: "habit", scope: "global")
    bad_scope = call_tool("write_memory", content: "x", kind: "reference", scope: "team")
    global_with_scope = call_tool("write_memory", content: "x", kind: "reference", scope: "global", scope_id: repository.id)

    expect(tool_error?(bad_kind)).to be true
    expect(error_text(bad_kind)).to be_present
    expect(tool_error?(bad_scope)).to be true
    expect(error_text(bad_scope)).to be_present
    expect(tool_error?(global_with_scope)).to be true
    expect(error_text(global_with_scope)).to include("scope_id must be omitted")
  end

  it "reads owned memories even when the repository is not attached" do
    unattached_repo = Factories.repository(user: user)
    memory = create_memory(scope_id: unattached_repo.id)

    response = call_tool("read_memory", memory_id: memory.id)

    expect(payload(response).dig(:memory, :id)).to eq(memory.id)
  end

  it "reads published memories from other users for attached repositories only" do
    other_user = Factories.user
    published = create_memory(user: other_user, published: true, content: "Shared deploy note.")
    private_memory = create_memory(user: other_user, content: "Private deploy note.")
    unattached_published = create_memory(
      user: other_user,
      scope_id: Factories.repository(user: other_user).id,
      published: true,
      content: "Not attached."
    )

    response = call_tool("read_memory", memory_id: published.id)
    private_response = call_tool("read_memory", memory_id: private_memory.id)
    unattached_response = call_tool("read_memory", memory_id: unattached_published.id)

    expect(payload(response).dig(:memory, :id)).to eq(published.id)
    expect(private_response.dig(:result, :isError)).to be true
    expect(unattached_response.dig(:result, :isError)).to be true
  end

  it "lists visible memories most recent first with optional filters" do
    global = create_memory(scope: "global", scope_id: nil, kind: "user_pref", content: "Use short answers.")
    repo_fact = create_memory(kind: "project_fact", content: "Rails app.")
    shared = create_memory(user: Factories.user, kind: "reference", content: "Shared runbook.", published: true)
    create_memory(user: Factories.user, kind: "reference", content: "Private note.")
    create_memory(scope_id: Factories.repository(user: user).id, content: "Own unattached repo.")

    response = call_tool("list_memories")
    filtered_response = call_tool("list_memories", scope: "repository", kind: "reference")

    expect(payload(response)[:memories].map { |memory| memory[:id] }).to eq([ shared.id, repo_fact.id, global.id ])
    expect(payload(filtered_response)[:memories].map { |memory| memory[:id] }).to eq([ shared.id ])
  end

  it "searches visible memory content case-insensitively and caps the limit" do
    second_repo = Factories.repository(user: user)
    chat_session.chat_attachments.create!(attachable: second_repo)
    create_memory(content: "Alpha deploy runbook.")
    second_repo_memory = create_memory(scope_id: second_repo.id, content: "alpha release checklist.")
    create_memory(content: "Completely different.")
    create_memory(user: Factories.user, content: "alpha private note.")
    shared = create_memory(user: Factories.user, scope_id: second_repo.id, content: "Shared ALPHA hint.", published: true)

    response = call_tool("search_memories", query: "alpha", limit: 500)
    ids = payload(response)[:memories].map { |memory| memory[:id] }

    expect(ids).to contain_exactly(shared.id, second_repo_memory.id, ChatMemory.find_by!(content: "Alpha deploy runbook.").id)
    expect(payload(response)[:memories].length).to be <= 50
  end

  it "deletes only memories owned by the caller" do
    owned = create_memory
    other = create_memory(user: Factories.user, published: true)

    response = call_tool("delete_memory", memory_id: owned.id)
    other_response = call_tool("delete_memory", memory_id: other.id)

    expect(payload(response)).to include(id: owned.id, deleted: true)
    expect(ChatMemory.exists?(owned.id)).to be false
    expect(other_response.dig(:result, :isError)).to be true
    expect(ChatMemory.exists?(other.id)).to be true
  end

  it "publishes only owned repository-scoped memories" do
    memory = create_memory
    global = create_memory(scope: "global", scope_id: nil)
    other = create_memory(user: Factories.user)

    response = call_tool("publish_memory", memory_id: memory.id)
    global_response = call_tool("publish_memory", memory_id: global.id)
    other_response = call_tool("publish_memory", memory_id: other.id)

    expect(payload(response).dig(:memory, :published)).to be true
    expect(memory.reload).to be_published
    expect(global_response.dig(:result, :isError)).to be true
    expect(error_text(global_response)).to include("global memories cannot be published")
    expect(other_response.dig(:result, :isError)).to be true
    expect(other.reload).not_to be_published
  end

  it "unpublishes only memories owned by the caller" do
    memory = create_memory(published: true)
    other = create_memory(user: Factories.user, published: true)

    response = call_tool("unpublish_memory", memory_id: memory.id)
    other_response = call_tool("unpublish_memory", memory_id: other.id)

    expect(payload(response).dig(:memory, :published)).to be false
    expect(memory.reload).not_to be_published
    expect(other_response.dig(:result, :isError)).to be true
    expect(other.reload).to be_published
  end
end
