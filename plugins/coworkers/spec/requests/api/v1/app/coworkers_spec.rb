require "rails_helper"

RSpec.describe "API: coworkers", type: :request do
  let(:owner) { Factories.user }

  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

  it "keeps coworker provenance out of slim navigation rows" do
    chat = ChatSession.create!(
      user: owner,
      title: "Engineering plan",
      last_message_at: Time.current,
      artifacts: { "opened_by_coworker" => { "id" => 7, "handle" => "maya", "name" => "Maya" } }
    )
    sign_in_as(owner)

    get "/api/v1/app/chats"

    chats = response.parsed_body.fetch("groups").flat_map { |group| group.fetch("chats") }
    expect(chats.find { |entry| entry.fetch("id") == chat.id }).not_to have_key("opened_by_coworker")
  end

  it "hides coworker workspace repositories from the repository list" do
    visible = Factories.repository(user: owner, owner: "acme", name: "application")
    workspace = Factories.repository(user: owner, owner: "acme", name: "coworker-home")
    Coworkers::WorkspaceRepository.create!(repository: workspace)
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-repository-list",
      workspace_repo: workspace.remote_url
    )
    sign_in_as(owner)

    get "/api/v1/app/repositories"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("active_repositories").pluck("id")).to contain_exactly(visible.id)
  end

  it "keeps a reused normal repository listed even when all workspace automation settings are disabled" do
    repository = Factories.repository(
      user: owner, owner: "acme", name: "shared-application",
      polling_enabled: false, auto_merge_enabled: false, external_pr_ingestion_enabled: false,
      main_branch_health_enabled: false, main_branch_repair_enabled: false,
      fork_auto_sync_enabled: false, pr_cost_footer_enabled: false
    )
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-shared-repository-list",
      workspace_repo: repository.remote_url
    )
    sign_in_as(owner)

    get "/api/v1/app/repositories"

    expect(response.parsed_body.fetch("active_repositories").pluck("id")).to include(repository.id)
  end

  it "keeps the completed permission cutover report out of coworker capabilities" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-report", workspace_repo: "https://github.com/acme/workspace.git")
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")
    # Core coworker tools now carry explicit descriptors; a grant with no registered tools is still a gap.
    coworker.grants.create!(capability: "workspace.shell", approval_policy: "auto")
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/capabilities"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key("permission_cutover_report")
  end

  it "does not expose credentials from journaling failure details" do
    repository = Factories.repository(user: owner, owner: "acme", name: "journal-workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-journal-redaction",
      workspace_repo: repository.remote_url
    )
    task = Coworkers::SystemSchedules.reconcile!(coworker)
    secret = "ghp_abcdefghijklmnopqrstuvwxyz123456"
    allow(task).to receive(:system_schedule_definition).and_return(Coworkers::Prompts::Journaling.new)
    task.record_fire_failure!(RuntimeError.new("push rejected for token=#{secret}"))
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/schedules"

    expect(response).to have_http_status(:ok)
    schedule = response.parsed_body.fetch("schedules").find { |item| item.fetch("id") == task.id }
    expect(schedule.fetch("last_system_result_reason")).to eq("RuntimeError: push rejected for token=[REDACTED]")
    expect(schedule.fetch("latest_result").to_json).not_to include(secret)
  end

  it "shows a threshold-level journaling failure before it becomes overdue" do
    repository = Factories.repository(user: owner, owner: "acme", name: "journal-attention-workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-journal-attention",
      workspace_repo: repository.remote_url
    )
    task = Coworkers::SystemSchedules.reconcile!(coworker)
    sign_in_as(owner)

    travel_to(Time.utc(2026, 11, 4, 3)) do
      task.update_columns(consecutive_failure_count: Coworkers::JournalingFailureAlert::FAILURE_THRESHOLD)
      task.record_system_result!(date: Date.new(2026, 11, 3), result: "failed", reason: "RuntimeError: workspace locked")

      get "/api/v1/app/coworkers/#{coworker.id}/schedules"
    end

    schedule = response.parsed_body.fetch("schedules").find { |item| item.fetch("id") == task.id }
    expect(schedule).to include(
      "journaling_overdue" => true,
      "last_system_result_reason" => "RuntimeError: workspace locked"
    )
  end

  it "adds coworker sender and receiver appearances to chat messages without per-message queries" do
    sender = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-payload", workspace_repo: "https://github.com/acme/maya.git", avatar_key: "comet")
    receiver = Coworkers::Coworker.create!(owner_user: owner, name: "Rin", handle: "rin-payload", workspace_repo: "https://github.com/acme/rin.git", avatar_key: "prism")
    chat = ChatSession.create!(user: owner, title: "Maya main")
    Coworkers::Chat.create!(coworker: sender, chat_session: chat, role: "main")
    3.times do
      chat.messages.create!(role: "user", content: {
        "text" => "Message from @maya-payload\n\nHello",
        "source" => "coworker_message",
        "coworker_message" => { "direction" => "incoming", "sender_id" => sender.id, "sender_handle" => sender.handle }
      }, skip_turn_trigger: true)
    end
    chat.messages.create!(role: "system", content: {
      "text" => "Message to @rin-payload\n\nHello",
      "source" => "coworker_message",
      "coworker_message" => { "direction" => "outgoing", "receiver_id" => receiver.id, "receiver_handle" => receiver.handle }
    }, skip_turn_trigger: true)
    sender.update!(state: "archived")
    sign_in_as(owner)
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] if payload[:sql].match?(/FROM [\"`]?coworkers[\"`]?/i)
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/api/v1/app/chats/#{chat.id}"
    end

    expect(response).to have_http_status(:ok)
    messages = response.parsed_body.fetch("messages")
    expect(messages.first.dig("plugin_message", "data", "appearance")).to include(
      "id" => sender.id, "name" => "Maya", "handle" => "maya-payload",
      "accent_hex" => sender.accent_hex, "avatar_key" => "comet", "avatar_url" => nil
    )
    expect(messages.last.dig("plugin_message", "data", "appearance")).to include("id" => receiver.id, "name" => "Rin", "handle" => "rin-payload")
    appearance_queries = queries.grep(/WHERE [\"`]?coworkers[\"`]?\.[\"`]?id[\"`]? IN/i)
    expect(appearance_queries.size).to eq(1)
  end

  it "does not disclose a foreign coworker's appearance from forged message metadata" do
    foreign_owner = Factories.user(email_address: "foreign-coworker-owner@example.com")
    foreign_coworker = Coworkers::Coworker.create!(
      owner_user: foreign_owner, name: "Private Agent", handle: "private-agent",
      workspace_repo: "https://github.com/private/workspace.git", avatar_key: "comet"
    )
    chat = ChatSession.create!(user: owner, title: "Owner chat")
    chat.messages.create!(role: "user", content: {
      "text" => "Message from @saved-handle\n\nDo not disclose the lookup target.",
      "source" => "coworker_message",
      "coworker_message" => {
        "direction" => "incoming", "sender_id" => foreign_coworker.id,
        "sender_handle" => "saved-handle"
      }
    }, skip_turn_trigger: true)
    sign_in_as(owner)

    get "/api/v1/app/chats/#{chat.id}"

    expect(response).to have_http_status(:ok)
    message = response.parsed_body.fetch("messages").sole
    expect(message.dig("plugin_message", "data", "appearance")).to be_nil
    expect(message.fetch("text")).to start_with("Message from @saved-handle")
    expect(message.dig("content", "coworker_message", "sender_handle")).to eq("saved-handle")
    expect(response.body).not_to include("Private Agent", "private-agent")
  end

  it "requires explicit owner confirmation for grant escalation and returns the updated tool surface" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-grant-api", workspace_repo: "https://github.com/acme/workspace.git")
    sign_in_as(owner)

    patch "/api/v1/app/coworkers/#{coworker.id}/grants", params: { capability: "workspace.files", approval_policy: "confirm" }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("confirmation_required")
    expect(coworker.grants).to be_empty

    patch "/api/v1/app/coworkers/#{coworker.id}/grants", params: {
      capability: "workspace.files", approval_policy: "confirm", confirmed: true,
      constraints: { confirm_paths: [ "SOUL.md", "AGENTS.md" ] }
    }
    expect(response).to have_http_status(:no_content)

    get "/api/v1/app/coworkers/#{coworker.id}/capabilities"
    expect(response.parsed_body.fetch("grants")).to contain_exactly(
      "capability" => "workspace.files", "approval_policy" => "confirm",
      "constraints" => { "confirm_paths" => %w[SOUL.md AGENTS.md] }
    )
  end

  it "does not let another user change coworker grants" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-grant-owner", workspace_repo: "https://github.com/acme/workspace.git")
    sign_in_as(Factories.user)

    patch "/api/v1/app/coworkers/#{coworker.id}/grants", params: { capability: "workspace.files", approval_policy: "off" }
    expect(response).to have_http_status(:not_found)
  end

  it "creates coworker schedules and includes them on the shared Schedules page" do
    repository = Factories.repository(user: owner, owner: "acme", name: "maya-workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-schedule-api",
      workspace_repo: repository.remote_url
    )
    sign_in_as(owner)

    post "/api/v1/app/coworkers/#{coworker.id}/schedules", params: {
      schedule: { name: "Morning briefing", prompt: "Prepare it.", kind: "cron", schedule_input: "Every day at 9:00 AM" }
    }

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("schedule", "after_run")).to eq("wake")
    task_id = response.parsed_body.dig("schedule", "id")
    expect(ScheduledTasks::Task.find(task_id).coworker_id).to eq(coworker.id)

    get "/api/v1/app/scheduled_tasks"
    expect(response.parsed_body.fetch("active_tasks")).to include(
      include("id" => task_id, "name" => "Morning briefing", "repository_id" => repository.id)
    )
  end

  it "does not pause or resume a fired coworker one-shot" do
    repository = Factories.repository(user: owner, owner: "acme", name: "one-shot-workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-one-shot-api",
      workspace_repo: repository.remote_url
    )
    task = coworker.schedules.create!(
      user: owner, repository: repository, name: "Once", prompt: "Run once.",
      kind: "one_shot", fire_at: 1.hour.from_now, pr_pileup_policy: "skip", auto_approve_mode: "never"
    )
    task.update!(state: "fired")
    sign_in_as(owner)

    post "/api/v1/app/coworkers/#{coworker.id}/schedules/#{task.id}/pause"
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/app/coworkers/#{coworker.id}/schedules/#{task.id}/resume"
    expect(response).to have_http_status(:unprocessable_content)

    expect(task.reload).to be_fired
  end

  it "lets only the signed-in owner confirm a coworker-authored proposal" do
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-proposer", workspace_repo: repository.remote_url
    )
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    proposal = chat.proposals.create!(
      repository: repository,
      proposer: coworker,
      slug: "job-owner-confirmed",
      title: "Owner-confirmed work",
      body: "Create this only after the owner confirms.",
      kind: "job",
      planned_execution_capabilities: { "os" => [ "linux" ] },
      planned_execution_source: "explicit"
    )
    chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Job proposal proposed." })

    expect(Mcp::Sidecar.chat_tool_names(chat, tier: :essential)).not_to include("confirm_proposal")
    expect(Job.where(issue_title: proposal.title)).to be_empty

    sign_in_as(owner)
    expect {
      post "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}/confirm"
    }.to change(Job, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(proposal.reload).to have_attributes(state: "confirmed", proposer: coworker)
    expect(proposal.job).to have_attributes(proposer: coworker)
    expect(response.parsed_body.dig("proposal", "proposer")).to eq(
      "type" => "coworker", "id" => coworker.id, "label" => "Maya", "handle" => "maya-proposer"
    )
  end

  it "updates proposed About text while the coworker action is pending" do
    chat = ChatSession.create!(user: owner)
    action = chat.pending_actions.create!(
      action: "create_coworker", requested_by: "agent",
      payload: { "name" => "Maya", "handle" => "maya", "workspace_repo" => "https://github.com/acme/homes.git", "about" => "Old role" }
    )
    chat.messages.create!(
      role: "tool_use", tool_name: "propose_coworker", tool_use_id: "coworker-1", pending_action: action,
      content: { "type" => "tool_use", "id" => "coworker-1", "name" => "propose_coworker", "input" => {} }
    )
    sign_in_as(owner)

    patch "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}", params: { about: "  role: Research director  " }

    expect(response).to have_http_status(:ok)
    expect(action.reload.payload["about"]).to eq("role: Research director")
    expect(response.parsed_body.dig("pending_actions", 0, "app_update_path")).to end_with("/pending_actions/#{action.id}")
    # The write answers with the pending-action slice it changed, not a whole
    # transcript, so the refreshed review travels on the card itself.
    expect(response.parsed_body.dig("pending_actions", 0, "review", "about")).to eq("role: Research director")
  end

  it "lists only the signed-in owner's coworkers with Syrus pinned separately" do
    owner.update!(agent_provider: "codex", codex_auth_mode: "api_key", codex_api_key: "secret")
    mine = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    other = Factories.user(email_address: "other@example.com")
    Coworkers::Coworker.create!(owner_user: other, name: "Hidden", handle: "hidden", workspace_repo: "https://github.com/acme/other.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("syrus", "built_in")).to be(true)
    expect(body.fetch("coworkers")).to contain_exactly(include("id" => mine.id, "handle" => "maya"))
    get "/api/v1/app/coworkers/options"
    expect(response.parsed_body.fetch("model_options")).to include(
      include("provider" => "codex", "models" => include(include("id" => AgentProviders::Codex.available_models.first.id)))
    )
  end

  it "loads weekly card spend with collection-wide aggregates" do
    3.times do |index|
      Coworkers::Coworker.create!(
        owner_user: owner, name: "Coworker #{index}", handle: "card-spend-#{index}",
        workspace_repo: "https://github.com/acme/workspace.git"
      )
    end
    sign_in_as(owner)

    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/api/v1/app/coworkers"
    end

    expect(response).to have_http_status(:ok)
    expect(queries.grep(/FROM ["`]chat_spend_entries["`]/i).size).to eq(1)
    expect(queries.grep(/FROM ["`]runs["`]/i).size).to eq(1)
  end

  it "groups coworker chats and includes their appearance in the chat list" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git", avatar_key: "comet")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    sign_in_as(owner)

    get "/api/v1/app/chats"

    group = JSON.parse(response.body).fetch("groups").find { |candidate| candidate["key"] == "coworkers" }
    expect(group.fetch("chats")).to contain_exactly(include("id" => chat.id))
    expect(JSON.parse(response.body).dig("agent_appearances", chat.id.to_s)).to include(
      "name" => "Maya", "avatar_key" => "comet", "coworker_id" => coworker.id,
      "coworker_chat_role" => "main", "side_chat_action_path" => "/api/v1/app/coworkers/#{coworker.id}/chats"
    )
  end

  it "keeps coworker and epic lookups bounded as the mixed chat index grows" do
    repositories = 3.times.map do |index|
      Factories.repository(user: owner, owner: "acme", name: "chat-index-#{index}")
    end
    epics = repositories.map.with_index do |repository, index|
      Factories.epic(user: owner, repository: repository, title: "Chat index epic #{index}")
    end
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-chat-index-budget",
      workspace_repo: repositories.first.remote_url
    )

    create_mixed_chats = lambda do |range|
      range.each do |index|
        repository = index.even? ? repositories[index % repositories.size] : nil
        chat = ChatSession.create!(
          user: owner, repository: repository, title: "Mixed chat #{index}",
          last_message_at: index.minutes.ago
        )
        Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "side") if (index % 3).zero?
        next unless index.even?

        epic = epics[index % epics.size] if (index % 4).zero?
        job = Factories.job_record(
          user: owner, repository: epic&.repository || repositories[index % repositories.size], epic: epic,
          issue_number: 10_000 + index, state: "implemented", issue_title: "Mixed job #{index}"
        )
        ChatAttachment.create!(chat_session: chat, attachable: job, attached_at: Time.current)
      end
    end
    capture_index_queries = lambda do
      queries = []
      callback = lambda do |_name, _started, _finished, _id, payload|
        queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get "/api/v1/app/chats" }
      expect(response).to have_http_status(:ok)
      queries
    end
    association_query_counts = lambda do |queries|
      {
        coworker_chats: queries.grep(/FROM ["`]?coworker_chats["`]?/i).size,
        coworkers: queries.grep(/FROM ["`]?coworkers["`]?/i).size,
        epics: queries.grep(/FROM ["`]?epics["`]?/i).size
      }
    end

    sign_in_as(owner)
    create_mixed_chats.call(0...6)
    small_counts = association_query_counts.call(capture_index_queries.call)
    create_mixed_chats.call(6...18)
    large_counts = association_query_counts.call(capture_index_queries.call)

    expect(large_counts).to eq(small_counts)
    expect(large_counts).to include(coworker_chats: 3, coworkers: 1, epics: 1)
  end

  it "scopes mention autocomplete without leaking the user or coworker directory" do
    rostered = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", role_summary: "Researcher", workspace_repo: "https://github.com/acme/workspace.git")
    available = Coworkers::Coworker.create!(owner_user: owner, name: "Nora", handle: "nora", workspace_repo: "https://github.com/acme/workspace.git")
    other_owner = Factories.user(email_address: "outsider@example.com")
    outsider = Coworkers::Coworker.create!(owner_user: other_owner, name: "Secret", handle: "secret", workspace_repo: "https://github.com/acme/other.git")
    chat = ChatSession.create!(user: owner, title: "Team chat")
    Coworkers::Chat.create!(coworker: rostered, chat_session: chat, role: "main")
    sign_in_as(owner)

    get "/api/v1/app/chats/#{chat.id}/mentionables"

    rows = response.parsed_body.fetch("mentionables")
    expect(rows.pluck("handle")).to eq([ owner.handle, "maya", "nora", "syrus" ])
    expect(rows.find { |row| row["kind"] == "coworker" && row["id"] == rostered.id }).to include("subtitle" => "Researcher", "add_to_chat" => false)
    expect(rows.find { |row| row["kind"] == "coworker" && row["id"] == available.id }).to include("add_to_chat" => true)
    expect(rows.none? { |row| row["kind"] == "coworker" && row["id"] == outsider.id }).to be(true)

    resolved = chat.resolve_mentions("Ask @maya and @syrus, but not @nora")
    expect(resolved.pluck("kind", "handle")).to eq([ [ "coworker", "maya" ], [ "syrus", "syrus" ] ])

    get "/api/v1/app/chats/#{chat.id}/mentionables", params: { q: outsider.handle }
    expect(response.parsed_body.fetch("mentionables")).to be_empty
  end

  it "does not offer a shared-chat reader their own coworkers" do
    recipient = Factories.user(email_address: "reader@example.com")
    Coworkers::Coworker.create!(owner_user: recipient, name: "Private", handle: "private", workspace_repo: "https://github.com/acme/private.git")
    chat = ChatSession.create!(user: owner, title: "Shared")
    ChatShare.create!(chat_session: chat, target: recipient, shared_by_user: owner)
    sign_in_as(recipient)

    get "/api/v1/app/chats/#{chat.id}/mentionables"
    expect(response.parsed_body.fetch("mentionables").pluck("handle")).not_to include("private")
  end

  it "adds and removes an owned coworker from a chat roster without duplicates" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    chat = ChatSession.create!(user: owner, title: "Plans")
    sign_in_as(owner)

    expect {
      post "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}"
    }.to change(Coworkers::ChatAgent, :count).by(1)
    expect(response).to have_http_status(:created)
    expect(Coworkers::ChatAgent.last).to have_attributes(added_by_user: owner, after_reply: "wake")

    expect {
      post "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}"
    }.not_to change(Coworkers::ChatAgent, :count)
    expect(response).to have_http_status(:created)

    patch "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}", params: { after_reply: "quiet" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("agent", "after_reply")).to eq("quiet")
    expect(Coworkers::ChatAgent.last.reload.after_reply).to eq("quiet")

    expect {
      delete "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}"
    }.to change(Coworkers::ChatAgent, :count).by(-1)
    expect(response).to have_http_status(:no_content)
  end

  it "distinguishes implicit coworker chats from removable roster entries" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-membership", workspace_repo: "https://github.com/acme/workspace.git")
    own_chat = ChatSession.create!(user: owner, title: "Maya main")
    roster_chat = ChatSession.create!(user: owner, title: "Planning")
    Coworkers::Chat.create!(coworker: coworker, chat_session: own_chat, role: "main")
    Coworkers::ChatAgent.create!(coworker: coworker, chat_session: roster_chat, added_by_user: owner)
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/chats"

    chats = response.parsed_body.fetch("available_chats").index_by { |chat| chat.fetch("id") }
    expect(chats.fetch(own_chat.id)).to include("implicit" => true, "rostered" => false)
    expect(chats.fetch(roster_chat.id)).to include("implicit" => false, "rostered" => true)
  end

  it "reports recent incoming and outgoing coworker message traffic" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-traffic", workspace_repo: "https://github.com/acme/workspace.git")
    chat = ChatSession.create!(user: owner, title: "Maya main")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    chat.messages.create!(role: "system", content: { "text" => "Sent", "coworker_message" => { "direction" => "outgoing" } })
    chat.update!(cumulative_cost_usd: 1.25)
    chat.messages.create!(role: "user", content: { "text" => "Received", "coworker_message" => { "direction" => "incoming" } }, skip_turn_trigger: true)
    chat.messages.create!(role: "system", content: { "text" => "Message to @rin was not delivered", "coworker_message" => { "direction" => "outgoing", "status" => "refused", "receiver_handle" => "rin" } })
    old = chat.messages.create!(role: "system", content: { "text" => "Old", "coworker_message" => { "direction" => "outgoing" } })
    old.update_columns(created_at: 31.days.ago)
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/activity"

    traffic = response.parsed_body.fetch("message_traffic")
    expect(traffic).to include("sent" => 1, "received" => 1, "window_days" => 30)
    expect(traffic.fetch("delivery_events")).to contain_exactly(
      include("status" => "refused", "receiver_handle" => "rin", "reason" => "Message to @rin was not delivered")
    )
  end

  it "refuses to add another user's coworker" do
    other = Factories.user(email_address: "other-roster@example.com")
    coworker = Coworkers::Coworker.create!(owner_user: other, name: "Private", handle: "private-agent", workspace_repo: "https://github.com/acme/private.git")
    chat = ChatSession.create!(user: owner, title: "Plans")
    sign_in_as(owner)

    expect {
      post "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}"
    }.not_to change(Coworkers::ChatAgent, :count)
    expect(response).to have_http_status(:not_found)
  end

  it "keeps list options and expensive tab details behind scoped endpoints" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-tabs", workspace_repo: "https://github.com/acme/workspace.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers"
    expect(response.parsed_body).not_to include("model_options", "grant_catalog")

    get "/api/v1/app/coworkers/options"
    expect(response.parsed_body).to include("accent_hexes", "model_options", "grant_catalog")

    get "/api/v1/app/coworkers/#{coworker.id}"
    expect(response.parsed_body.fetch("coworker")).not_to include(
      "soul", "available_chats", "grants", "schedules", "message_traffic"
    )

    get "/api/v1/app/coworkers/#{coworker.id}/capabilities"
    expect(response.parsed_body).to include("grants", "grant_catalog")
    expect(response.parsed_body).not_to have_key("permission_cutover_report")
  end

  it "removes the superseded profile and memory presentation endpoints" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "workspace-only", workspace_repo: "https://github.com/acme/workspace.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/profile"
    expect(response).to have_http_status(:not_found)

    get "/api/v1/app/coworkers/#{coworker.id}/memory"
    expect(response).to have_http_status(:not_found)
  end

  it "returns bad request for a malformed activity cursor" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-cursor", workspace_repo: "https://github.com/acme/workspace.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/activity", params: { jobs_cursor: "broken" }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_cursor")
  end

  it "returns bad request for a conversation cursor with an invalid timestamp" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-conversation-cursor", workspace_repo: "https://github.com/acme/workspace.git")
    cursor = Base64.urlsafe_encode64(JSON.generate([ "not-a-date", 42 ]), padding: false)
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/conversation_index", params: { cursor: cursor }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_cursor")
  end

  it "does not expose another owner's conversation index" do
    other = Factories.user(email_address: "other-conversation-owner@example.com")
    coworker = Coworkers::Coworker.create!(owner_user: other, name: "Private", handle: "private-conversation-index", workspace_repo: "https://github.com/acme/private.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/conversation_index"

    expect(response).to have_http_status(:not_found)
  end

  it "moves a newly rostered coworker into the addressable autocomplete scope" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-roster", workspace_repo: "https://github.com/acme/workspace.git")
    chat = ChatSession.create!(user: owner, title: "Plans")
    sign_in_as(owner)

    get "/api/v1/app/chats/#{chat.id}/mentionables"
    expect(response.parsed_body.fetch("mentionables").find { |row| row["kind"] == "coworker" && row["id"] == coworker.id }).to include("add_to_chat" => true)

    post "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}"
    get "/api/v1/app/chats/#{chat.id}/mentionables"
    expect(response.parsed_body.fetch("mentionables").find { |row| row["kind"] == "coworker" && row["id"] == coworker.id }).to include("add_to_chat" => false)
    expect(chat.resolve_mentions("Ask @maya-roster")).to include(include("kind" => "coworker", "id" => coworker.id))
  end

  it "delegates the exact roster-mentioned coworker without starting a source-chat turn" do
    maya = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git",
      chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
    mayank = Coworkers::Coworker.create!(
      owner_user: owner, name: "Mayank", handle: "mayank", workspace_repo: "https://github.com/acme/workspace.git"
    )
    member = Factories.user(email_address: "group-member@example.com")
    chat = ChatSession.create!(user: owner, title: "Planning", conversation_kind: "group")
    chat.chat_participants.create!(user: member, role: "member")
    [ maya, mayank ].each { |coworker| Coworkers::ChatAgent.create!(chat_session: chat, coworker: coworker, added_by_user: owner) }
    sign_in_as(member)

    post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Please ask @maya" } }

    message = chat.messages.last
    expect(enqueued_jobs).to include(hash_including(job: Coworkers::MentionDeliveryJob, args: [ message.id, maya.id ]))
    expect(enqueued_jobs).not_to include(hash_including(job: ChatTurnJob))
    expect(message.mentions).to contain_exactly(include("kind" => "coworker", "id" => maya.id, "handle" => "maya"))
    expect(message.mentions).not_to include(include("id" => mayank.id))
    expect(chat.reload).not_to be_turn_in_flight
  end

  it "keeps the host chat repository when adding a coworker to its roster" do
    host_repository = Factories.repository(user: owner, owner: "acme", name: "host")
    workspace_repository = Factories.repository(user: owner, owner: "acme", name: "coworker-home")
    chat = ChatSession.create!(user: owner, repository: host_repository, title: "Planning")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-host-repository",
      workspace_repo: workspace_repository.remote_url
    )
    sign_in_as(owner)

    post "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}"

    expect(response).to have_http_status(:created)
    expect(chat.reload.repository).to eq(host_repository)
    expect(chat.coworker_chat).to be_nil
  end

  it "does not address or leave a turn in flight for an unrostered coworker in a group chat" do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-private", workspace_repo: "https://github.com/acme/workspace.git"
    )
    member = Factories.user(email_address: "unrostered-member@example.com")
    chat = ChatSession.create!(user: owner, title: "Planning", conversation_kind: "group")
    chat.chat_participants.create!(user: member, role: "member")
    sign_in_as(member)

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Please ask @maya-private" } }
    }.not_to have_enqueued_job(ChatTurnJob)

    expect(chat.messages.last.mentions).to eq([])
    expect(chat.reload).not_to be_turn_in_flight
  end

  it "delegates back-to-back coworker mentions without starting source-chat turns" do
    maya = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-serial", workspace_repo: "https://github.com/acme/workspace.git")
    member = Factories.user(email_address: "serial-member@example.com")
    chat = ChatSession.create!(user: owner, title: "Planning", conversation_kind: "group")
    chat.chat_participants.create!(user: member, role: "member")
    Coworkers::ChatAgent.create!(chat_session: chat, coworker: maya, added_by_user: owner)
    sign_in_as(member)

    2.times do |index|
      post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "@maya-serial request #{index + 1}" } }
      expect(response).to have_http_status(:ok)
    end

    jobs = enqueued_jobs.select { |job| job.fetch(:job) == Coworkers::MentionDeliveryJob }
    expect(jobs.size).to eq(2)
    expect(jobs.map { |job| job.fetch(:args).last }).to eq([ maya.id, maya.id ])
    expect(enqueued_jobs).not_to include(hash_including(job: ChatTurnJob))
    expect(chat.reload).not_to be_turn_in_flight
  end

  it "creates side chats in the coworker's Phase 1 home-branch workspace" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url,
      chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
    sign_in_as(owner)

    expect { post "/api/v1/app/coworkers/#{coworker.id}/chats" }.to change(Coworkers::Chat.where(role: "side"), :count).by(1)

    expect(response).to have_http_status(:created)
    chat = coworker.coworker_chats.find_by!(role: "side").chat_session
    expect(response.parsed_body).to include("chat_path" => "/chats/#{chat.id}")
    expect(chat).to have_attributes(
      repository: repository, chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
    expect(owner.accessible_chat_sessions.find(chat.id)).to eq(chat)
  end

  it "updates editable profile fields without changing the workspace remote" do
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-profile", workspace_repo: "https://github.com/acme/workspace.git"
    )
    sign_in_as(owner)

    patch "/api/v1/app/coworkers/#{coworker.id}", params: {
      name: "Maya Updated", handle: coworker.handle, about: "Updated profile", accent_hex: "#B6492E", avatar_key: "orbit",
      chat_provider: "codex", chat_model: "gpt-6.1-sol", workspace_repo: "https://github.com/evil/ignored.git"
    }

    expect(response).to have_http_status(:ok)
    expect(coworker.reload).to have_attributes(
      name: "Maya Updated", role_summary: "Updated profile", accent_hex: "#B6492E", avatar_key: "orbit",
      chat_provider: "codex", chat_model: "gpt-6.1-sol", workspace_repo: "https://github.com/acme/workspace.git"
    )
  end

  it "omits hidden mention sessions from the coworker's default chat list" do
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-hidden-mention",
      workspace_repo: "https://github.com/acme/workspace.git"
    )
    main_chat = ChatSession.create!(user: owner, title: "Maya")
    source_chat = ChatSession.create!(user: owner, title: "Planning")
    mention_chat = ChatSession.create!(user: owner, title: "Maya in Planning", hidden_at: Time.current)
    Coworkers::Chat.create!(coworker:, chat_session: main_chat, role: "main")
    Coworkers::Chat.create!(coworker:, chat_session: mention_chat, source_chat_session: source_chat, role: "mention")
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/chats"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("chats").pluck("id")).to eq([ main_chat.id ])
    expect(owner.accessible_chat_sessions.find(mention_chat.id)).to eq(mention_chat)
  end

  it "ignores dedicated coworker repositories when inferring a new chat repository default" do
    ordinary_repository = Factories.repository(user: owner, owner: "acme", name: "ordinary")
    workspace_repository = Factories.repository(user: owner, owner: "acme", name: "workspace-default")
    ordinary_chat = ChatSession.create!(user: owner, repository: ordinary_repository)
    ordinary_chat.update_columns(created_at: 2.hours.ago)
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-default", workspace_repo: workspace_repository.remote_url
    )
    Coworkers::WorkspaceRepository.create!(repository: workspace_repository)
    main_chat = ChatSession.create!(user: owner, repository: workspace_repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: main_chat, role: "main")
    side_chat = Coworkers::SpawnChat.call(coworker: coworker, prompt: "Investigate", server_context: nil)
    sign_in_as(owner)

    get "/api/v1/app/chats/new"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("default_repository_id" => ordinary_repository.id)
    expect(response.parsed_body.fetch("repositories")).to include(include("id" => workspace_repository.id))
    expect(main_chat.reload.repository).to eq(workspace_repository)
    expect(side_chat.reload.repository).to eq(workspace_repository)
  end

  it "falls back to the first active repository when only dedicated coworker repositories have chats" do
    fallback_repository = Factories.repository(user: owner, owner: "acme", name: "aardvark")
    workspace_repository = Factories.repository(user: owner, owner: "acme", name: "zebra-workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-fallback", workspace_repo: workspace_repository.remote_url
    )
    Coworkers::WorkspaceRepository.create!(repository: workspace_repository)
    chat = ChatSession.create!(user: owner, repository: workspace_repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    sign_in_as(owner)

    get "/api/v1/app/chats/new"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("default_repository_id" => fallback_repository.id)
  end

  it "lists and decides owner-scoped queued approvals and counts them in the nav badge" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-approvals", workspace_repo: "https://github.com/acme/workspace.git")
    main_chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: main_chat, role: "main")
    approval = main_chat.pending_actions.create!(
      action: "coworker_tool_call", requested_by: "agent",
      payload: { "tool_name" => "ask_user_question", "arguments" => { "questions" => [ { "question" => "Proceed?" } ] }, "run_id" => 42, "approval_policy" => "queue", "approval_inbox" => true }
    )
    interactive_confirmation = main_chat.pending_actions.create!(
      action: "coworker_tool_call", requested_by: "agent",
      payload: { "tool_name" => "ask_user_question", "arguments" => { "questions" => [ { "question" => "Live confirmation?" } ] }, "approval_policy" => "confirm", "approval_inbox" => false }
    )
    other = Factories.user(email_address: "other-approvals@example.com")
    other_coworker = Coworkers::Coworker.create!(owner_user: other, name: "Other", handle: "other-approval-agent", workspace_repo: "https://github.com/acme/other.git")
    other_chat = ChatSession.create!(user: other, title: "Other")
    Coworkers::Chat.create!(coworker: other_coworker, chat_session: other_chat, role: "main")
    other_chat.pending_actions.create!(action: "coworker_tool_call", requested_by: "agent", payload: { "tool_name" => "ask_user_question", "arguments" => {}, "approval_policy" => "queue", "approval_inbox" => true })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/approvals"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("approvals")).to contain_exactly(include(
      "id" => approval.id, "tool_name" => "ask_user_question", "tool_input" => { "questions" => [ { "question" => "Proceed?" } ] }, "run_id" => 42
    ))
    expect(response.parsed_body.fetch("approvals").pluck("id")).not_to include(interactive_confirmation.id)

    get "/api/v1/app/coworkers/sidebar_badge"
    expect(response.parsed_body).to eq("v" => ApiVersion::CURRENT, "count" => 1)

    expect {
      post "/api/v1/app/coworkers/#{coworker.id}/approvals/#{approval.id}/reject"
    }.to have_enqueued_job(ChatTurnJob)
    expect(response).to have_http_status(:ok)
    expect(approval.reload).to be_rejected
    expect(main_chat.messages.last.extract_text_from_content).to include("Pending action rejected")
  end

  it "does not let another owner decide a coworker's approval" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-private-approval", workspace_repo: "https://github.com/acme/workspace.git")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    approval = chat.pending_actions.create!(action: "coworker_tool_call", requested_by: "agent", payload: { "tool_name" => "ask_user_question", "arguments" => {}, "approval_policy" => "queue", "approval_inbox" => true })
    sign_in_as(Factories.user(email_address: "approval-intruder@example.com"))

    post "/api/v1/app/coworkers/#{coworker.id}/approvals/#{approval.id}/reject"

    expect(response).to have_http_status(:not_found)
    expect(approval.reload).to be_pending
  end

  it "browses the home branch through repository content and flags partial files" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-workspace", workspace_repo: repository.remote_url)
    stub_repository_content(
      repository, ref: "coworkers/maya-workspace",
      files: { "README.md" => ("# Workspace\n" + ("x" * Coworkers::WorkspaceBrowser::MAX_FILE_BYTES)) },
      truncated_tree: true
    )
    stub_repository_content(repository, ref: repository.default_branch, files: {})
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { path: "README.md" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "remote" => repository.remote_url, "branch" => "coworkers/maya-workspace", "partial" => true
    )
    expect(response.parsed_body.fetch("selected_file")).to include("path" => "README.md", "truncated" => true)
  end

  it "searches and combines bounded workspace metadata filters with stable pagination" do
    stub_const("Coworkers::WorkspaceBrowser::PAGE_SIZE", 1)
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "workspace-search", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: "coworkers/workspace-search", files: {
      "memory/daily/notes.md" => "😀İx needle in memory",
      "memory/daily/other.txt" => "needle in another format",
      "projects/notes.md" => "needle outside memory",
      "assets/photo.png" => "\0binary"
    })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: {
      search: "needle", extension: "md", folder: "memory/daily", path_prefix: "memory", filename: "note"
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("results")).to contain_exactly(
      include("path" => "memory/daily/notes.md", "snippet" => include("needle"), "binary" => false,
        "highlights" => [ { "start" => 5, "length" => 6 } ])
    )
    expect(response.parsed_body).to include("total" => 1, "next_cursor" => nil)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { content_kind: "binary", min_size: 2, max_size: 100 }
    expect(response.parsed_body.fetch("results")).to contain_exactly(include("path" => "assets/photo.png", "binary" => true))

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { path_prefix: "memory" }
    first_page = response.parsed_body
    expect(first_page.fetch("results").size).to eq(1)
    expect(first_page.fetch("next_cursor")).to be_present

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { path_prefix: "memory", cursor: first_page.fetch("next_cursor") }
    expect(response.parsed_body.fetch("results").pluck("path"))
      .not_to eq(first_page.fetch("results").pluck("path"))
  end

  it "filters and sorts by bounded last-modified history including root files" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "dated-workspace", workspace_repo: repository.remote_url)
    root = stub_repository_content(repository, ref: "root-revision", files: { "root.md" => "root" })
    head = stub_repository_content(repository, ref: "head-revision", files: { "root.md" => "root", "recent.md" => "recent" })
    stub_repository_content(repository, ref: "coworkers/dated-workspace", files: { "root.md" => "root", "recent.md" => "recent" })
    root_date = Time.zone.parse("2026-01-01T12:00:00Z")
    head_date = Time.zone.parse("2026-02-01T12:00:00Z")
    stub_repository_commits(repository, ref: "coworkers/dated-workspace", commits: [
      { sha: head.id, message: "recent", date: head_date },
      { sha: root.id, message: "root", date: root_date }
    ])
    stub_repository_diff(repository, base: "root-revision", head: "head-revision", files: [ { path: "recent.md", status: "added" } ])
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: {
      modified_after: "2025-12-31", modified_before: "2026-02-02", sort: "modified"
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("results").pluck("path")).to eq([ "recent.md", "root.md" ])
    expect(response.parsed_body.fetch("results").pluck("last_modified_at")).to eq([ head_date.iso8601, root_date.iso8601 ])
    expect(response.parsed_body.fetch("incomplete_reasons")).to be_empty
  end

  it "batches bounded workspace content search through the repository reader" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "bounded-search", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: "coworkers/bounded-search", files: {
      "one.md" => "needle one", "two.md" => "needle two"
    })
    sign_in_as(owner)

    expect_any_instance_of(FakeRepositoryContentProvider).to receive(:workspace_files)
      .once.with(anything, paths: match_array(%w[one.md two.md]), max_bytes: 256.kilobytes, last_modified: false, history_limit: 25)
      .and_call_original

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { search: "needle" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("results").size).to eq(2)
  end

  it "marks searches incomplete when truncated content can hide matches" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "truncated-search", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: "coworkers/truncated-search", files: {
      "large.md" => (("x" * Coworkers::WorkspaceBrowser::MAX_FILE_BYTES) + "needle")
    })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { search: "needle" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("results" => [], "partial" => true)
    expect(response.parsed_body.fetch("incomplete_reasons")).to include("content_limit")
  end

  it "reports the candidate cap before date filtering removes unexamined files" do
    stub_const("Coworkers::WorkspaceBrowser::MAX_SEARCH_FILES", 1)
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "limited-history", workspace_repo: repository.remote_url)
    head = stub_repository_content(repository, ref: "head-revision", files: { "one.md" => "one", "two.md" => "two" })
    stub_repository_content(repository, ref: "coworkers/limited-history", files: { "one.md" => "one", "two.md" => "two" })
    stub_repository_commits(repository, ref: "coworkers/limited-history", commits: [
      { sha: head.id, message: "head", date: Time.zone.parse("2026-02-01T12:00:00Z") }
    ])
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { modified_after: "2026-01-01", sort: "modified" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("partial" => true)
    expect(response.parsed_body.fetch("incomplete_reasons")).to include("search_limit")
  end

  it "rejects invalid workspace cursors" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "cursor-search", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: "coworkers/cursor-search", files: { "SOUL.md" => "identity" })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace", params: { cursor: "not-a-cursor" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_cursor")
  end

  it "distinguishes an unreachable workspace and a missing home branch" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "missing-workspace", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: repository.default_branch, files: {})
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/workspace"
    expect(response).to have_http_status(:service_unavailable)

    stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("offline"))
    get "/api/v1/app/coworkers/#{coworker.id}/workspace"
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.dig("error", "code")).to eq("remote_unavailable")
  end

  it "offers only the owner's coworkers as typed read-only share targets" do
    mine = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    other_owner = Factories.user(email_address: "other-owner@example.com")
    hidden = Coworkers::Coworker.create!(owner_user: other_owner, name: "Hidden", handle: "hidden", workspace_repo: "https://github.com/acme/other.git")
    chat = ChatSession.create!(user: owner, title: "Plans")
    sign_in_as(owner)

    get "/api/v1/app/chats/#{chat.id}/share_candidates"
    expect(response.parsed_body.fetch("targets")).to include(include("target_type" => "Coworkers::Coworker", "target_id" => mine.id, "kind" => "coworker"))
    expect(response.parsed_body.fetch("targets")).not_to include(include("target_id" => hidden.id, "kind" => "coworker"))

    post "/api/v1/app/chats/#{chat.id}/shares", params: { target_type: "Coworkers::Coworker", target_id: mine.id }
    expect(response).to have_http_status(:created)
    expect(chat.chat_shares.find_by!(target: mine).shared_by_user).to eq(owner)

    post "/api/v1/app/chats/#{chat.id}/shares", params: { target_type: "Coworkers::Coworker", target_id: hidden.id }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "badges and filters coworker chats on chat and global search" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED, tokenize = 'porter unicode61')
    SQL
    SearchRecord.connection.execute("CREATE TABLE IF NOT EXISTS chat_search_metadata (key TEXT PRIMARY KEY, value TEXT)")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    coworker_chat = ChatSession.create!(user: owner, title: "Maya")
    syrus_chat = ChatSession.create!(user: owner, title: "Syrus")
    Coworkers::Chat.create!(coworker: coworker, chat_session: coworker_chat, role: "main")
    message = coworker_chat.messages.create!(role: "user", content: { "text" => "calendar needle" })
    syrus_chat.messages.create!(role: "user", content: { "text" => "engineering needle" })
    ChatMessageSearchIndex.insert(message)
    sign_in_as(owner)

    get "/api/v1/app/filters/schema", params: { subject: "chat_message" }
    coworker_field = response.parsed_body.fetch("fields").find { |field| field.fetch("field") == "coworker_id" }
    expect(coworker_field.fetch("values")).to include({ "value" => "syrus", "label" => "Syrus" }, { "value" => coworker.id.to_s, "label" => "Maya" })

    get "/api/v1/app/chats/search", params: { coworker_id: coworker.id }
    expect(response.parsed_body.fetch("results")).to contain_exactly(
      include("chat_session_id" => coworker_chat.id, "badges" => [ { "kind" => "coworker", "id" => coworker.id, "name" => "Maya" } ])
    )

    filter = Filters::QueryParam.encode("and" => [ { "field" => "coworker_id", "op" => "is", "value" => coworker.id } ])
    get "/api/v1/app/search", params: { query: "calendar", q: filter, types: [ "chat" ] }
    expect(response.parsed_body.fetch("results")).to contain_exactly(
      include("id" => message.id, "badges" => [ { "kind" => "coworker", "id" => coworker.id, "name" => "Maya" } ])
    )
  end

  it "applies every coworker operator on the chat search surface" do
    maya = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    ada = Coworkers::Coworker.create!(owner_user: owner, name: "Ada", handle: "ada", workspace_repo: "https://github.com/acme/workspace.git")
    maya_chat = ChatSession.create!(user: owner, title: "Maya")
    ada_chat = ChatSession.create!(user: owner, title: "Ada")
    syrus_chat = ChatSession.create!(user: owner, title: "Syrus")
    Coworkers::Chat.create!(coworker: maya, chat_session: maya_chat, role: "main")
    Coworkers::Chat.create!(coworker: ada, chat_session: ada_chat, role: "main")
    [ maya_chat, ada_chat, syrus_chat ].each { |chat| chat.messages.create!(role: "user", content: { "text" => chat.title }) }
    sign_in_as(owner)

    expectations = {
      "is" => [ maya_chat.id ],
      "is_not" => [ ada_chat.id, syrus_chat.id ],
      "is_one_of" => [ maya_chat.id, syrus_chat.id ],
      "is_none_of" => [ ada_chat.id ]
    }
    expectations.each do |op, expected_ids|
      value = op.in?(%w[is_one_of is_none_of]) ? "#{maya.id},syrus" : maya.id
      get "/api/v1/app/chats/search", params: { coworker_id: value, coworker_op: op }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("results").pluck("chat_session_id")).to match_array(expected_ids)
    end
  end

  it "stops applying plugin chat filters after rendering an operator error" do
    sign_in_as(owner)
    allow(ChatIdentityContributions).to receive(:search_ownership).and_return([
      { "key" => "first", "filter_field" => "coworker_id" },
      { "key" => "second", "filter_field" => "coworker_id" }
    ])

    get "/api/v1/app/chats/search", params: { coworker_id: "syrus", coworker_op: "unsupported" }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("code" => "bad_request")
  end

  it "removes the routes and sidebar contribution when the plugin is disabled" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-disabled-chat", workspace_repo: "https://github.com/acme/workspace.git")
    chat = ChatSession.create!(user: owner, title: "Historical agent chat", last_message_at: Time.current)
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    PluginRecord.find_by!(name: "coworkers").update!(enabled: false)
    sign_in_as(owner)

    get "/api/v1/app/coworkers"
    expect(response).to have_http_status(:not_found)
    expect(Coworkers::SidebarPages.sidebar_pages).to be_present
    expect(surface_implementations(:sidebar_pages)).not_to include(Coworkers::SidebarPages)
    expect(Syrus::PluginRegistry.providers_for(:chat_identity_provider)).not_to include(Coworkers::ChatIdentityProvider)

    get "/api/v1/app/chats"
    expect(response.parsed_body.fetch("groups").flat_map { |group| group.fetch("chats") }.pluck("id")).to include(chat.id)
    expect(response.parsed_body.fetch("agent_appearances")).to be_empty

    get "/api/v1/app/chats/#{chat.id}/mentionables"
    expect(response.parsed_body.fetch("mentionables").pluck("kind")).not_to include("coworker")
  end

  it "removes chat identity surfaces while the plugin is unhealthy" do
    sign_in_as(owner)
    health = Syrus::PluginRegistry.health
    allow(Syrus::PluginRegistry).to receive(:health_for).and_return(health)
    allow(Syrus::PluginRegistry).to receive(:health).and_return(health)
    allow(health).to receive(:healthy?).and_call_original
    allow(health).to receive(:healthy?).with("coworkers").and_return(false)

    expect(Syrus::PluginRegistry.providers_for(:chat_identity_provider)).not_to include(Coworkers::ChatIdentityProvider)
    get "/api/v1/app/coworkers"
    expect(response).to have_http_status(:not_found)
  end

  it "shows owner-scoped provisioning status and audits manual acknowledgement" do
    attempt = Coworkers::ProvisioningAttempt.create!(owner_user: owner, idempotency_key: "visible",
      remote_owner: "acme", remote_name: "homes", handle: "maya-cleanup", branch: "coworkers/maya-cleanup",
      expected_seeded_commit: "a" * 40, state: "manual_attention", manual_attention_at: Time.current)
    Coworkers::ProvisioningAttempt.create!(owner_user: Factories.user, idempotency_key: "hidden",
      remote_owner: "acme", remote_name: "homes", handle: "other-cleanup", branch: "coworkers/other-cleanup",
      state: "cleanup_pending")
    sign_in_as(owner)

    get "/api/v1/app/coworkers"
    expect(response.parsed_body.fetch("provisioning_attempts").pluck("id")).to eq([ attempt.id ])

    post "/api/v1/app/coworkers/provisioning_attempts/#{attempt.id}/acknowledge"
    expect(response).to have_http_status(:ok)
    expect(attempt.reload).to have_attributes(acknowledged_by: owner)
    expect(attempt.acknowledged_at).to be_present
  end

  it "enqueues an owner-requested cleanup retry" do
    attempt = Coworkers::ProvisioningAttempt.create!(owner_user: owner, idempotency_key: "retry",
      remote_owner: "acme", remote_name: "homes", handle: "maya-retry", branch: "coworkers/maya-retry",
      expected_seeded_commit: "a" * 40, state: "cleanup_pending")
    sign_in_as(owner)

    expect {
      post "/api/v1/app/coworkers/provisioning_attempts/#{attempt.id}/retry"
    }.to have_enqueued_job(Coworkers::ProvisioningCleanupJob).with(attempt.id)
    expect(response).to have_http_status(:accepted)
  end

  it "exposes durable unsaved state and replaces its delayed retry" do
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-retry-save", workspace_repo: repository.remote_url)
    chat = ChatSession.create!(user: owner, repository:, title: "Maya")
    link = Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    link.update!(unsaved_workspace_branch: "coworkers/chat/#{coworker.id}-#{chat.id}", unsaved_workspace_path: "/tmp/preserved",
      unsaved_workspace_error: "Internal Server Error", unsaved_workspace_failure_kind: "transient",
      unsaved_workspace_operation: "chat_branch", unsaved_workspace_attempt_count: 3,
      unsaved_workspace_retry_scheduled_at: Time.current, unsaved_workspace_retry_token: "old-token")
    sign_in_as(owner)
    get "/api/v1/app/coworkers/#{coworker.id}/chats"
    expect(response.parsed_body.dig("chats", 0, "unsaved_workspace")).to include("attempt_count" => 3)
    expect { post "/api/v1/app/coworkers/#{coworker.id}/workspace/retry", params: { chat_id: link.id } }
      .to have_enqueued_job(Coworkers::WorkspaceSaveRetryJob)
    expect(response).to have_http_status(:accepted)
    expect(link.reload.unsaved_workspace_retry_token).not_to eq("old-token")
  end
end
