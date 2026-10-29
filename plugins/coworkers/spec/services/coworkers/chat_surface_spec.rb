require "rails_helper"

RSpec.describe "Coworker chat surface" do
  let(:owner) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya",
      workspace_repo: repository.remote_url
    )
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "coworker surface spec") }

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    Coworkers::SearchExtension.install_into(scope)
  end

  after { scope.dispose }

  def names(tier: :essential)
    McpToolRegistry.tools_for_context(McpToolContext.from_chat_session(chat.reload), tier: tier)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }
  end

  it "never gives an admin-owned coworker admin, repair, coding, local, or runtime tools" do
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")

    expect(names).to contain_exactly("list_jobs", "search_jobs", "read_job")
    expect(names).not_to include("admin_overview", "force_fail_job", "run_command", "runtime_start")
  end

  it "advertises every tool only when its named grant exists" do
    entries = McpToolRegistry.entries(surface: :coworker)
    expect(entries).to all(have_attributes(capability: be_present))

    entries.reject(&:interactive_only).each do |entry|
      coworker.grants.delete_all
      expect(names(tier: entry.tier)).not_to include(entry.tool_name)

      coworker.grants.create!(capability: entry.capability.to_s, approval_policy: "auto")
      expect(names(tier: entry.tier)).to include(entry.tool_name)
    end
  end

  it "offers interactive-only tools only for an interactive turn" do
    coworker.grants.create!(capability: "chat.message_owner", approval_policy: "auto")
    expect(names).not_to include("ask_user_question", "suggest_next_step")

    message = chat.messages.create!(role: "user", content: { "text" => "Hello" })
    chat.update_columns(current_turn_message_id: message.id, turn_in_flight: true)

    expect(names).to include("ask_user_question", "suggest_next_step")
  end

  it "limits list, search, and read tools to the coworker's own and explicitly shared chats" do
    coworker.grants.create!(capability: "chats.read_shared", approval_policy: "auto")
    private_chat = ChatSession.create!(user: owner, title: "Owner private")
    shared_chat = ChatSession.create!(user: owner, title: "Shared")
    ChatShare.create!(chat_session: shared_chat, target: coworker, shared_by_user: owner)

    context = { chat_session: chat }
    list_response = Mcp::Tools::ListChatsTool.call(server_context: context)
    listed_ids = JSON.parse(list_response.content.first[:text]).fetch("chats").pluck("id")
    expect(listed_ids).to contain_exactly(chat.id, shared_chat.id)

    Mcp::Tools::AuthorizationSupport.with_server_context(context) do
      expect(Mcp::Tools::SearchChatsTool.send(:searchable_chat_session_ids))
        .to match_array([ chat.id, shared_chat.id ])
    end

    expect(Mcp::Tools::ReadChatMessagesTool.call(server_context: context, chat_session_id: shared_chat.id)).not_to be_error
    expect(Mcp::Tools::ReadChatMessagesTool.call(server_context: context, chat_session_id: private_chat.id)).to be_error
    expect(names(tier: :deferred)).not_to include("send_chat_message")

    shared_chat.chat_shares.destroy_all
    expect(Mcp::Tools::ReadChatMessagesTool.call(server_context: context, chat_session_id: shared_chat.id)).to be_error
  end

  it "filters agent chat search by coworker and returns the coworker name" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED, tokenize = 'porter unicode61')
    SQL
    SearchRecord.connection.execute("CREATE TABLE IF NOT EXISTS chat_search_metadata (key TEXT PRIMARY KEY, value TEXT)")
    coworker.grants.create!(capability: "chats.read_shared", approval_policy: "auto")
    indexed = chat.messages.create!(role: "user", content: { "text" => "calendar needle" })
    ChatMessageSearchIndex.insert(indexed)
    Syrus::PluginRegistry.register(:chat_result_decorator, Coworkers::ChatResultDecorator)
    context = { chat_session: chat }

    response = Mcp::Tools::SearchChatsTool.call(server_context: context, query: "calendar", coworker_id: coworker.id)
    result = JSON.parse(response.content.first[:text]).fetch("results").first

    expect(result).to include("chat_session_id" => chat.id, "coworker_name" => "Maya")
  end

  it "enforces auto, confirm, and queue approval policies" do
    message = chat.messages.create!(role: "user", content: { "text" => "Hello" })
    chat.update_columns(current_turn_message_id: message.id, turn_in_flight: true)
    context = { chat_session: chat, current_message: message }
    questions = [ { question: "Proceed?" } ]

    grant = coworker.grants.create!(capability: "chat.message_owner", approval_policy: "auto")
    tool = Mcp::Sidecar.chat_tools(chat).find { |candidate| McpToolRegistry.tool_name_for(candidate) == "ask_user_question" }
    expect { tool.call(server_context: context, questions: questions) }.to change(chat.agent_questions, :count).by(1)

    grant.update!(approval_policy: "confirm")
    question_count = chat.agent_questions.count
    expect { tool.call(server_context: context, questions: questions) }
      .to change { chat.pending_actions.where(action: "coworker_tool_call").count }.by(1)
    expect(chat.agent_questions.count).to eq(question_count)
    pending = chat.pending_actions.where(action: "coworker_tool_call").last
    expect { pending.confirm!(user: owner) }.to change(chat.agent_questions, :count).by(1)
    expect(pending.reload).to be_confirmed

    grant.update!(approval_policy: "queue")
    response = tool.call(server_context: context, questions: questions)
    expect(JSON.parse(response.content.first[:text])).to include("approval_policy" => "queue")
    expect(chat.pending_actions.last).to be_pending
  end

  it "offers only read-only memory tools without a grant" do
    allow(AgentMemory).to receive(:enabled?).and_return(true)

    essential_names = Mcp::Sidecar.chat_tool_names(chat, tier: :essential)
    expect(essential_names).to include("read_memory")
    deferred_names = Mcp::Sidecar.chat_tool_names(chat, tier: :deferred)
    expect(deferred_names).to include("search_memories", "list_memories")
    expect(essential_names + deferred_names).not_to include(
      "write_memory", "update_memory", "delete_memory", "publish_memory", "unpublish_memory"
    )
  end

  it "gives memory reads exactly the owner's visibility across repositories and scopes" do
    other_repository = Factories.repository(user: owner)
    inaccessible_repository = Factories.repository(user: Factories.user)
    other_user = Factories.user
    owner_global = AgentMemory::Entry.create!(user: owner, kind: "user_pref", scope: "global", content: "owner global needle")
    owner_instance = AgentMemory::Entry.create!(user: owner, kind: "reference", scope: "instance", content: "owner instance needle")
    owner_team = AgentMemory::Entry.create!(user: owner, kind: "reference", scope: "team", scope_id: 123, content: "owner team needle")
    owner_repository = AgentMemory::Entry.create!(user: owner, kind: "project_fact", scope: "repository", scope_id: other_repository.id, content: "owner repository needle")
    published_repository = AgentMemory::Entry.create!(user: other_user, kind: "reference", scope: "repository", scope_id: other_repository.id, content: "published repository needle", published: true)
    unpublished_repository = AgentMemory::Entry.create!(user: other_user, kind: "reference", scope: "repository", scope_id: other_repository.id, content: "unpublished repository needle")
    private_other_user = AgentMemory::Entry.create!(user: other_user, kind: "user_pref", scope: "global", content: "private other user needle")
    inaccessible_published = AgentMemory::Entry.create!(user: other_user, kind: "reference", scope: "repository", scope_id: inaccessible_repository.id, content: "inaccessible published needle", published: true)
    context = { chat_session: chat }

    list_response = AgentMemory::Tools::ListMemoriesTool.call(server_context: context, limit: 100)
    listed_ids = JSON.parse(list_response.content.first[:text]).fetch("memories").pluck("id")
    expect(listed_ids).to include(owner_global.id, owner_instance.id, owner_repository.id, published_repository.id)
    expect(listed_ids).not_to include(owner_team.id, unpublished_repository.id, private_other_user.id, inaccessible_published.id)

    search_response = AgentMemory::Tools::SearchMemoriesTool.call(query: "needle", server_context: context, limit: 50)
    searched_ids = JSON.parse(search_response.content.first[:text]).fetch("memories").pluck("id")
    expect(searched_ids).to match_array(listed_ids)

    expect(AgentMemory::Tools::ReadMemoryTool.call(id: owner_repository.id, server_context: context)).not_to be_error
    expect(AgentMemory::Tools::ReadMemoryTool.call(id: published_repository.id, server_context: context)).not_to be_error
    expect(AgentMemory::Tools::ReadMemoryTool.call(id: owner_team.id, server_context: context)).to be_error
    expect(AgentMemory::Tools::ReadMemoryTool.call(id: unpublished_repository.id, server_context: context)).to be_error
    expect(AgentMemory::Tools::ReadMemoryTool.call(id: private_other_user.id, server_context: context)).to be_error
    expect(AgentMemory::Tools::ReadMemoryTool.call(id: inaccessible_published.id, server_context: context)).to be_error
  end

  it "offers coworker messaging only with its named grant" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(Mcp::Sidecar.chat_tool_names(chat, tier: :essential)).not_to include("message_coworker")

    coworker.grants.create!(capability: "coworker.message", approval_policy: "auto")

    expect(Mcp::Sidecar.chat_tool_names(chat.reload, tier: :essential)).to include("message_coworker")
  end

  it "offers coworker messaging only with its named grant" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(Mcp::Sidecar.chat_tool_names(chat, tier: :essential)).not_to include("message_coworker")

    coworker.grants.create!(capability: "coworker.message", approval_policy: "auto")

    expect(Mcp::Sidecar.chat_tool_names(chat.reload, tier: :essential)).to include("message_coworker")
  end

  it "turns revoked workspace grants into provider-native denials" do
    files = coworker.grants.create!(capability: "workspace.files", approval_policy: "auto")
    shell = coworker.grants.create!(capability: "workspace.shell", approval_policy: "auto")
    claude = ChatProviders::Claude.new(chat: chat)

    expect(claude.send(:disallowed_tools)).to eq([ "AskUserQuestion" ])
    shell.destroy!
    expect(claude.send(:disallowed_tools)).to include("Bash")
    files.destroy!
    expect(claude.send(:disallowed_tools)).to include(*ChatProviders::Claude::COWORKER_FILE_TOOLS)

    codex = ChatProviders::Codex.new(chat: chat)
    expect { codex.send(:require_full_coworker_workspace_access!) }
      .to raise_error(ArgumentError, /cannot safely run/)
  end

  it "checks out the home branch and withholds owner invocation credentials" do
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, chat.messages.create!(role: "user", content: { "text" => "Hello" }))
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(Pathname("/tmp/coworker-root"))
    allow(ChatWorkspace).to receive(:ensure_branch_checkout!)
      .with(chat, repository, "coworkers/maya")
      .and_return(Pathname("/tmp/coworker-home"))

    expect(job.send(:ensure_workspace!)).to eq(Pathname("/tmp/coworker-home"))
    expect(job.send(:cli_invocation_env, double(provider: "claude"))).to eq({})
    expect(GithubClient).not_to receive(:for)
    yielded = nil
    job.send(:with_git_askpass_env) { |env| yielded = env }
    expect(yielded).to eq("GIT_TERMINAL_PROMPT" => "0")
  end
end
