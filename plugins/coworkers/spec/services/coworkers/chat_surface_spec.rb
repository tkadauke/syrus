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
    PluginRecord.find_by!(name: "coworkers").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    Filters.subject(:chat_message)
    Coworkers::SearchExtension.install_into(scope)
  end

  after { scope.dispose }

  def names(tier: :essential)
    McpToolRegistry.tools_for_context(McpToolContext.from_chat_session(chat.reload), tier: tier)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }
  end

  def coworker_tool(name)
    Mcp::Sidecar.chat_tools(chat.reload, tier: :essential)
      .find { |tool| McpToolRegistry.tool_name_for(tool) == name }
  end

  def response_payload(response)
    JSON.parse(response.content.first.fetch(:text))
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

  it "exposes both proposal tools with the proposal grant and keeps them absent without it" do
    expect(names).not_to include("propose_job", "propose_epic_with_jobs")

    coworker.grants.create!(capability: "syrus.propose_job", approval_policy: "auto")

    expect(names).to include("propose_job", "propose_epic_with_jobs")
    expect(names).not_to include("list_proposals", "confirm_proposal", "delete_proposal")
  end

  it "creates ordinary pending Job proposal cards with coworker provenance" do
    coworker.grants.create!(capability: "syrus.propose_job", approval_policy: "auto")

    response = coworker_tool("propose_job").call(
      repo: repository.slug,
      title: "Improve release notes",
      description: "Make the release summary clearer.",
      planned_execution: { capabilities: { os: [ "linux" ] } },
      server_context: { chat_session: chat }
    )

    expect(response).not_to be_error
    proposal = ChatProposal.find(response_payload(response).fetch("id"))
    expect(proposal).to have_attributes(chat_session: chat, proposer: coworker, state: "proposed")
    expect(response_payload(response).fetch("proposer")).to eq(
      "type" => "coworker", "id" => coworker.id, "label" => "Maya", "handle" => "maya"
    )
    expect(App::ChatMessagePayload.proposal(proposal, chat_session: chat, repository: repository).fetch(:proposer)).to eq(
      type: "coworker", id: coworker.id, label: "Maya", handle: "maya"
    )
    expect(proposal.messages).to contain_exactly(have_attributes(role: "assistant"))
    expect(Job.where(issue_title: "Improve release notes")).to be_empty
  end

  it "creates an ordinary pending Epic card and child cards with coworker provenance" do
    coworker.grants.create!(capability: "syrus.propose_job", approval_policy: "auto")

    response = coworker_tool("propose_epic_with_jobs").call(
      epic: {
        slug: "release-readiness",
        title: "Release readiness",
        description: "Prepare the release.",
        target_repo: repository.slug
      },
      jobs: [ {
        slug: "prepare-release",
        title: "Prepare release",
        description: "Build the release artifacts.",
        planned_execution: { capabilities: { os: [ "linux" ] } }
      } ],
      server_context: { chat_session: chat }
    )

    expect(response).not_to be_error
    proposal = ChatProposal.find(response_payload(response).fetch("id"))
    expect(proposal).to have_attributes(chat_session: chat, proposer: coworker, state: "proposed")
    expect(response_payload(response).fetch("proposer")).to eq(
      "type" => "coworker", "id" => coworker.id, "label" => "Maya", "handle" => "maya"
    )
    expect(proposal.child_proposals.sole).to have_attributes(proposer: coworker, state: "proposed")
    expect(proposal.messages).to contain_exactly(have_attributes(role: "assistant"))
    expect(Epic.where(title: "Release readiness")).to be_empty
    expect(Job.where(issue_title: "Prepare release")).to be_empty
  end

  it "preserves proposal validation and repository visibility for coworkers" do
    coworker.grants.create!(capability: "syrus.propose_job", approval_policy: "auto")
    inaccessible = Factories.repository(user: Factories.user, owner: "private", name: "repo")

    missing_placement = coworker_tool("propose_job").call(
      repo: repository.slug, title: "Unplaced work", description: "Missing placement.",
      server_context: { chat_session: chat }
    )
    inaccessible_target = coworker_tool("propose_job").call(
      repo: inaccessible.slug,
      title: "Private work",
      description: "Must remain invisible.",
      planned_execution: { capabilities: { os: [ "linux" ] } },
      server_context: { chat_session: chat }
    )

    expect(missing_placement).to be_error
    expect(missing_placement.content.first.fetch(:text)).to include("planned_execution.capabilities is required")
    expect(inaccessible_target).to be_error
    expect(inaccessible_target.content.first.fetch(:text)).to include("repository not found")
    expect(chat.proposals).to be_empty
  end

  it "requires separate grant-policy approval before drafting when configured for confirmation" do
    coworker.grants.create!(capability: "syrus.propose_job", approval_policy: "confirm")

    response = coworker_tool("propose_job").call(
      repo: repository.slug,
      title: "Confirm first",
      description: "The owner must allow this draft.",
      planned_execution: { capabilities: { os: [ "linux" ] } },
      server_context: { chat_session: chat }
    )

    expect(response).not_to be_error
    expect(response_payload(response)).to include("approval_policy" => "confirm")
    expect(chat.proposals).to be_empty
    expect(chat.pending_actions.last).to have_attributes(action: "coworker_tool_call", state: "pending")
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

  it "runs interactive question and suggestion helpers without grant-policy approval" do
    message = chat.messages.create!(role: "user", content: { "text" => "Hello" })
    chat.update_columns(current_turn_message_id: message.id, turn_in_flight: true)
    context = { chat_session: chat, current_message: message }
    questions = [ { question: "Proceed?" } ]

    coworker.grants.create!(capability: "chat.message_owner", approval_policy: "confirm")
    question_tool = coworker_tool("ask_user_question")
    suggestion_tool = coworker_tool("suggest_next_step")
    helper_entries = McpToolRegistry.entries(surface: :coworker).select do |entry|
      entry.tool.in?([ question_tool, suggestion_tool ])
    end

    expect(helper_entries).to all(have_attributes(mutation: true, read_only?: false, interactive_only: true))

    question_response = nil
    expect { question_response = question_tool.call(server_context: context, questions: questions) }
      .to change(chat.agent_questions, :count).by(1)
    expect(response_payload(question_response)).to include("question_id" => chat.agent_questions.last.id)
    expect(chat.pending_actions.where(action: "coworker_tool_call")).to be_empty

    response = suggestion_tool.call(server_context: context, text: "Draft the follow-up")

    expect(response_payload(response)).to include("suggested_next_step" => "Draft the follow-up")
    expect(chat.pending_actions.where(action: "coworker_tool_call")).to be_empty
    expect(chat.reload.suggested_next_step).to eq("Draft the follow-up")

    chat.messages.create!(role: "assistant", content: { "text" => "Done" })
    expect(chat.reload.suggested_next_step).to eq("Draft the follow-up")

    chat.messages.create!(role: "user", content: { "text" => "Draft the follow-up" })
    expect(chat.reload.suggested_next_step).to be_nil
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

  it "offers all workspace mutations on every coworker turn" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    tool_names = %w[write_coworker_file edit_coworker_file move_coworker_file delete_coworker_file]

    expect(Mcp::Sidecar.chat_tool_names(chat, tier: :essential)).to include(*tool_names)
    coworker.grants.create!(capability: "workspace.files", approval_policy: "auto")

    expect(Mcp::Sidecar.chat_tool_names(chat.reload, tier: :essential)).to include(*tool_names)
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

  it "uses the coworker chat branch lifecycle and withholds owner invocation credentials" do
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, chat.messages.create!(role: "user", content: { "text" => "Hello" }))
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(Pathname("/tmp/coworker-root"))
    lifecycle = class_double(Coworkers::ChatWorkspaceLifecycle, applies_to?: true)
    allow(lifecycle).to receive(:prepare!).with(chat_session: chat).and_return(Pathname("/tmp/coworker-chat"))
    allow(lifecycle).to receive(:finalize!).with(chat_session: chat)
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_workspace_lifecycle).and_return([ lifecycle ])

    expect(job.send(:ensure_workspace!)).to eq(Pathname("/tmp/coworker-chat"))
    job.send(:finalize_plugin_workspace!)
    expect(lifecycle).to have_received(:finalize!).with(chat_session: chat)
    expect(job.send(:cli_invocation_env, double(provider: "claude"))).to eq({})
    expect(GithubClient).not_to receive(:for)
    yielded = nil
    job.send(:with_git_askpass_env) { |env| yielded = env }
    expect(yielded).to eq("GIT_TERMINAL_PROMPT" => "0")
  end

  it "runs home-branch persistence before releasing the turn lock" do
    message = chat.messages.create!(role: "user", content: { "text" => "Remember this" })
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, message)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_turn_finalizer).and_return([ Coworkers::HomeBranchPersistence ])
    allow(Coworkers::HomeBranchPersistence).to receive(:after_chat_turn)

    job.send(:finalize_plugin_turns!)

    expect(Coworkers::HomeBranchPersistence).to have_received(:after_chat_turn).with(chat_session: chat, user_message: message)
  end

  it "keeps failed persistence recoverable and posts an actionable error" do
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_turn_finalizer).and_return([ Coworkers::HomeBranchPersistence ])
    allow(Coworkers::HomeBranchPersistence).to receive(:after_chat_turn).and_raise("push conflict")

    expect { job.send(:finalize_plugin_turns!) }.to change(chat.messages.where(role: "system"), :count).by(1)
    expect(chat.messages.order(:id).last.content.fetch("text")).to include("still recoverable locally", "push conflict")
  end
end
