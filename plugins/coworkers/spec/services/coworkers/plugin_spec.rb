require "rails_helper"

RSpec.describe "Coworkers plugin" do
  let(:owner) { User.create!(email_address: "owner@example.com", password: "password123") }

  it "declares presentation copy for every permission descriptor" do
    body = Rails.root.join("plugins/coworkers/app/services/permissions/coworker_actions.rb").read
    declarations = body.scan(/CapabilityDescriptor\.new\((.*?)\n\s*\)/m)

    expect(declarations).not_to be_empty
    expect(declarations.flatten).to all(include("presentation:"))
  end

  it "owns its adapters outside core except for actor-neutral permission policy" do
    core_paths = %w[
      app/services/permissions/coworker_*.rb
      app/services/mcp/coworker_*.rb
      app/services/mcp/tools/coworker_*.rb
      app/services/mcp/tools/discover_coworker_*.rb
      app/services/mcp/tools/request_permission_revocation_tool.rb
      app/services/mcp/tools/surrender_permission_lease_tool.rb
      app/services/pending_actions/coworker_*.rb
    ].flat_map { |pattern| Rails.root.glob(pattern) }

    expect(core_paths.map { |path| path.relative_path_from(Rails.root).to_s }).to contain_exactly(
      "app/services/permissions/coworker_default_policy.rb",
      "app/services/mcp/tools/coworker_observability_authorization.rb"
    )
    expect(Rails.root.glob("plugins/coworkers/app/services/coworkers/chat_parity.rb")).not_to be_empty
    expect(Rails.root.glob("plugins/coworkers/app/services/permissions/coworker_*.rb")).not_to be_empty
    expect(Rails.root.glob("plugins/coworkers/app/services/pending_actions/coworker_*.rb")).not_to be_empty
  end

  it "owns every migration whose behavior depends on coworker data" do
    # Ownership is what the plugin's purge owns: its tables and its inline
    # fields on core tables. Core features may still mention coworkers by
    # name (the core runtime-image service builds the coworker base image),
    # so the word alone is not evidence of plugin data.
    purge = Syrus::PluginPurge.new("coworkers").report
    owned = purge.tables + purge.inline_fields.map(&:column)
    owned_pattern = /\b(?:#{owned.map { |name| Regexp.escape(name) }.join("|")})\b/
    core_migrations = Rails.root.glob("db/migrate/*.rb").select { |path| path.read.match?(owned_pattern) }

    expect(core_migrations).to be_empty
    expect(Rails.root.glob("plugins/coworkers/db/migrate/*.rb").map { |path| path.basename.to_s }).to include(
      "20261031162746_add_coworker_wake_fields.rb",
      "20261101193036_reset_coworker_legacy_authority.rb",
      "20261104120818_migrate_coworker_grants_to_permission_rules.rb",
      "20261104140858_add_unsaved_workspace_to_coworker_chats.rb",
      "20261106105035_create_coworker_review_contexts.rb",
      "20261117201026_add_mention_sessions_to_coworker_chats.rb",
      "20261117202643_add_mention_owner_destinations_and_after_reply.rb",
      "20261118155251_repair_coworker_main_chat_constraint.rb"
    )
  end

  it "reports only plugin-owned tables for an explicit purge" do
    report = Syrus::PluginPurge.new("coworkers").report

    expect(report.tables).to contain_exactly(
      "coworker_chats",
      "coworker_grants",
      "coworker_provisioning_attempts",
      "coworker_review_contexts",
      "coworker_workspace_conflicts",
      "coworker_workspace_repositories",
      "coworkers",
      "coworkers_chat_agents"
    )
    expect(report.tables).not_to include("review_evidences", "runs", "scheduled_tasks")
    expect(report.inline_fields).to contain_exactly(
      have_attributes(table: "scheduled_tasks", column: "coworker_id"),
      have_attributes(table: "scheduled_tasks", column: "after_run"),
      have_attributes(table: "runs", column: "coworker_wake_enqueued_at")
    )
  end

  it "is experimental and disabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "coworkers" }

    expect(manifest).to be_experimental
    expect(manifest).not_to be_default_enabled
    expect(manifest.optionally_depends_on).to include("calendar")
    expect(Array(manifest.provides["calendar:event_source"])).to include(Coworkers::CalendarEventSource)
  end

  it "removes its Calendar contribution without disabling Coworkers", :reset_plugin_registry do
    AppSetting.current.update!(beta_mode_enabled: true)
    Syrus::PluginRegistry.clear_beta_mode_cache!
    calendar = PluginRecord.find_or_initialize_by(name: "calendar")
    coworkers = PluginRecord.find_or_initialize_by(name: "coworkers")
    calendar.update!(enabled: true)
    coworkers.update!(enabled: false)
    Syrus::Host::Installer.sync!
    coworkers.update!(enabled: true)
    Syrus::Host::Installer.sync!
    expect(Syrus::PluginRegistry.providers_for("calendar:event_source"))
      .to include(Coworkers::CalendarEventSource)

    calendar.update!(enabled: false)
    Syrus::Host::Installer.sync!
    expect(Syrus::PluginRegistry.providers_for("calendar:event_source"))
      .not_to include(Coworkers::CalendarEventSource)
    expect(coworkers.reload.enabled?).to be(true)
  end

  it "declares metrics and its sampler only while enabled" do
    coworkers = PluginRecord.find_or_create_by!(name: "coworkers")
    coworkers.update!(enabled: true)
    Syrus::Host::Installer.sync!

    expect(Syrus::Metrics.registry.declared?(:syrus_coworkers_journaling_state)).to be(true)
    expect(Syrus::Metrics.samplers).to include(Coworkers::MetricsSampler)

    coworkers.update!(enabled: false)
    Syrus::Host::Installer.sync!

    expect(Syrus::Metrics.registry.declared?(:syrus_coworkers_journaling_state)).to be(false)
    expect(Syrus::Metrics.samplers).not_to include(Coworkers::MetricsSampler)
  end

  it "keeps its capability compatibility baseline aligned with its chat tool inventory" do
    registrations = Permissions::CapabilityRegistryValidator.send(
      :plugin_registrations, Coworkers::ChatToolSet, :chat_mcp_tool_set
    )

    expect(Permissions::CapabilityRegistryValidator.new(registrations).findings).to be_empty
  end

  it "registers the owner-only Job visibility restriction before contributing coworker tasks" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    restriction = Syrus::Plugin::Policy.restrictions(:job_visibility_restrictions)
      .find { |candidate| candidate == Coworkers::JobVisibilityRestriction }

    expect(restriction).to eq(Coworkers::JobVisibilityRestriction)
    expect(restriction).to include(Syrus::Plugin::JobVisibilityRestriction)
    expect(restriction.origin_key).to eq("coworkers")
  end

  it "does not allow the coworker task kind to exist without its visibility restriction" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    next expect(Job::Kind.values).not_to include("coworker_task") unless Job::Kind.values.include?("coworker_task")

    restrictions = Syrus::Plugin::Policy.restrictions(:job_visibility_restrictions)
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


  it "does not expose a roster mention through the source chat turn context" do
    repository = Factories.repository(user: owner, owner: "acme", name: "coworker-workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-turn", workspace_repo: repository.remote_url,
      chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
    chat = ChatSession.create!(user: owner, title: "Planning")
    Coworkers::ChatAgent.create!(chat_session: chat, coworker: coworker, added_by_user: owner)
    message = chat.messages.build(
      role: "user", content: { "text" => "Ask @maya-turn" },
      mentions: [ { "kind" => "coworker", "id" => coworker.id, "handle" => coworker.handle, "start" => 4, "end" => 14 } ]
    )
    message.skip_turn_trigger = true
    message.save!
    scope = Syrus::EffectScope.new(label: "rostered coworker turn spec")
    Coworkers::ChatExtension.install_into(scope)

    expect(chat.coworker).to be_a(Coworker::Syrus)
    expect(Coworkers::ChatTurnLifecycle.applies_to?(chat_session: chat, user_message: message)).to be(false)
    expect(chat).not_to respond_to(:agent_turn_context)
    expect(chat).not_to respond_to(:coworker_roster_mention)
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

  it "registers an enabled-only coworker chat filter with owner-scoped options" do
    mine = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    other_user = Factories.user(email_address: "other-coworkers@example.com")
    Coworkers::Coworker.create!(owner_user: other_user, name: "Hidden", handle: "hidden", workspace_repo: "git@example.com:other.git")
    linked_chat = ChatSession.create!(user: owner, title: "Maya")
    syrus_chat = ChatSession.create!(user: owner, title: "Syrus")
    Coworkers::Chat.create!(coworker: mine, chat_session: linked_chat, role: "main")
    linked_message = linked_chat.messages.create!(role: "user", content: { "text" => "linked" })
    syrus_message = syrus_chat.messages.create!(role: "user", content: { "text" => "syrus" })
    plugin_record = PluginRecord.find_by!(name: "coworkers")
    plugin_record.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    chip = Filters::Registry.find("coworker_id", subject: :chat_message)

    expect(chip.schema_values(owner)).to eq([ { "value" => "syrus", "label" => "Syrus" }, { "value" => mine.id.to_s, "label" => "Maya" } ])
    expect(chip.new(scope: ChatMessage.all, op: :is, value: mine.id, user: owner).apply).to contain_exactly(linked_message)
    expect(chip.new(scope: ChatMessage.all, op: :is, value: "syrus", user: owner).apply).to contain_exactly(syrus_message)
    expect(chip.new(scope: ChatMessage.all, op: :is_not, value: mine.id, user: owner).apply).to include(syrus_message)

    plugin_record.update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    expect(Filters::Registry.fields(subject: :chat_message)).not_to include("coworker_id")
  end
  it "cleans plugin rows up with their core owners" do
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::DataCleanup.install_into(scope)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    repository = Factories.repository(user: owner)
    Coworkers::WorkspaceRepository.create!(repository: repository)
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    chat.destroy!
    expect(Coworkers::Chat.where(coworker: coworker)).to be_empty

    repository.destroy!
    expect(Coworkers::WorkspaceRepository.where(repository_id: repository.id)).to be_empty

    owner.destroy!
    expect(Coworkers::Coworker.where(id: coworker.id)).to be_empty
  ensure
    scope&.dispose
  end
end
