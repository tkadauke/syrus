require "rails_helper"

RSpec.describe "Coworkers plugin" do
  let(:owner) { User.create!(email_address: "owner@example.com", password: "password123") }

  it "is experimental and disabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "coworkers" }

    expect(manifest).to be_experimental
    expect(manifest).not_to be_default_enabled
  end

  it "registers the owner-only Job visibility restriction before contributing coworker tasks" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "coworkers" }
    restriction = manifest.provides.fetch(:job_visibility_restriction)

    expect(restriction).to eq(Coworkers::JobVisibilityRestriction)
    expect(restriction).to include(Syrus::Plugin::JobVisibilityRestriction)
    expect(restriction.origin_key).to eq("coworkers")
  end

  it "does not allow the coworker task kind to exist without its visibility restriction" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    next expect(Job::Kind.values).not_to include("coworker_task") unless Job::Kind.values.include?("coworker_task")

    restrictions = Syrus::PluginRegistry.providers_for(:job_visibility_restriction)
    expect(restrictions.map(&:origin_key)).to include("coworkers")
  end

  it "resolves an unlinked chat to the built-in Syrus coworker" do
    chat = ChatSession.create!(user: owner, title: "Existing chat")
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::ChatExtension.install_into(scope)

    expect(chat.coworker).to be_a(Coworker::Syrus)
    expect(chat.coworker).to have_attributes(owner_user: owner, handle: "syrus", workspace_repo: nil)
  ensure
    scope&.dispose
  end

  it "resolves linked chats and contributes their coworker as a mentionable" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::ChatExtension.install_into(scope)

    expect(chat.coworker).to eq(coworker)
    expect(Coworkers::MentionableProvider.mentionables(chat: chat)).to contain_exactly(coworker)
  ensure
    scope&.dispose
  end


  it "selects a roster-mentioned coworker as the active turn context" do
    repository = Factories.repository(user: owner, owner: "acme", name: "coworker-workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-turn", workspace_repo: repository.remote_url,
      chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
    chat = ChatSession.create!(user: owner, title: "Planning")
    Coworkers::ChatAgent.create!(chat_session: chat, coworker: coworker, added_by_user: owner)
    coworker.grants.create!(capability: "workspace.files", approval_policy: "auto")
    message = chat.messages.build(
      role: "user", content: { "text" => "Ask @maya-turn" },
      mentions: [ { "kind" => "coworker", "id" => coworker.id, "handle" => coworker.handle, "start" => 4, "end" => 14 } ]
    )
    message.skip_turn_trigger = true
    message.save!
    chat.update_columns(current_turn_message_id: message.id)
    scope = Syrus::EffectScope.new(label: "rostered coworker turn spec")
    Coworkers::ChatExtension.install_into(scope)

    context = chat.reload.agent_turn_context(message)

    expect(chat.coworker).to eq(coworker)
    expect(context).to have_attributes(
      coworker: coworker, effective_chat_provider: "codex", chat_model: "gpt-6.1-sol",
      chat_effort: "high", repository: repository
    )
    expect(McpToolContext.from_chat_session(context)).to have_attributes(
      role: AgentRole::COWORKER_CHAT, granted_capabilities: [ "workspace.files" ]
    )

    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, message)
    job.instance_variable_set(:@agent_chat, context)
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(Pathname("/tmp/roster-chat"))
    lifecycle = class_double(Coworkers::ChatWorkspaceLifecycle, applies_to?: true)
    allow(lifecycle).to receive(:prepare!).with(chat_session: chat).and_return(Pathname("/tmp/roster-coworker"))
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_workspace_lifecycle).and_return([ lifecycle ])

    expect(job.send(:chat_provider)).to have_attributes(provider: "codex")
    expect(job.send(:ensure_workspace!)).to eq(Pathname("/tmp/roster-coworker"))
    expect(job.send(:resume_session_id_for, nil)).to be_nil
  ensure
    scope&.dispose
  end

  it "removes the chat extension when disabled" do
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::ChatExtension.install_into(scope)
    expect(ChatSession.new).to respond_to(:coworker)

    scope.dispose
    expect(ChatSession.new).not_to respond_to(:coworker)
  end

  it "decorates linked chats in one query and leaves Syrus chats unbadged" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    coworker_chat = ChatSession.create!(user: owner, title: "Maya")
    syrus_chat = ChatSession.create!(user: owner, title: "Syrus")
    Coworkers::Chat.create!(coworker: coworker, chat_session: coworker_chat, role: "main")

    expect(Coworkers::ChatResultDecorator.chat_result_badges(chat_sessions: [ coworker_chat, syrus_chat ])).to eq(
      coworker_chat.id => [ { kind: "coworker", id: coworker.id, name: "Maya" } ]
    )
  end

  it "registers a reversible coworker chat filter with owner-scoped options" do
    mine = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    other_user = Factories.user(email_address: "other-coworkers@example.com")
    Coworkers::Coworker.create!(owner_user: other_user, name: "Hidden", handle: "hidden", workspace_repo: "git@example.com:other.git")
    linked_chat = ChatSession.create!(user: owner, title: "Maya")
    syrus_chat = ChatSession.create!(user: owner, title: "Syrus")
    Coworkers::Chat.create!(coworker: mine, chat_session: linked_chat, role: "main")
    linked_message = linked_chat.messages.create!(role: "user", content: { "text" => "linked" })
    syrus_message = syrus_chat.messages.create!(role: "user", content: { "text" => "syrus" })
    scope = Syrus::EffectScope.new(label: "coworker filter spec")
    Coworkers::SearchExtension.install_into(scope)
    chip = Filters::Registry.find("coworker_id", subject: :chat_message)

    expect(chip.schema_values(owner)).to eq([ { "value" => "syrus", "label" => "Syrus" }, { "value" => mine.id.to_s, "label" => "Maya" } ])
    expect(chip.new(scope: ChatMessage.all, op: :is, value: mine.id, user: owner).apply).to contain_exactly(linked_message)
    expect(chip.new(scope: ChatMessage.all, op: :is, value: "syrus", user: owner).apply).to contain_exactly(syrus_message)
    expect(chip.new(scope: ChatMessage.all, op: :is_not, value: mine.id, user: owner).apply).to include(syrus_message)

    scope.dispose
    expect(Filters::Registry.fields(subject: :chat_message)).not_to include("coworker_id")
  ensure
    scope&.dispose
  end
  it "cleans plugin rows up with their core owners" do
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::DataCleanup.install_into(scope)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    chat.destroy!
    expect(Coworkers::Chat.where(coworker: coworker)).to be_empty

    owner.destroy!
    expect(Coworkers::Coworker.where(id: coworker.id)).to be_empty
  ensure
    scope&.dispose
  end
end
