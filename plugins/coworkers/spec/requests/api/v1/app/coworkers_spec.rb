require "rails_helper"

RSpec.describe "API: coworkers", type: :request do
  let(:owner) { Factories.user }

  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

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
    tool_message = response.parsed_body.fetch("messages").find { |message| message["tool_name"] == "propose_coworker" }
    expect(tool_message.dig("pending_action", "review", "about")).to eq("role: Research director")
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
    expect(body.fetch("model_options")).to include(
      include("provider" => "codex", "models" => include(include("id" => AgentProviders::Codex.available_models.first.id)))
    )
  end

  it "groups coworker chats and includes their appearance in the chat list" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git", avatar_key: "comet")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    sign_in_as(owner)

    get "/api/v1/app/chats"

    group = JSON.parse(response.body).fetch("groups").find { |candidate| candidate["key"] == "coworkers" }
    expect(group.fetch("chats")).to contain_exactly(include("id" => chat.id, "agent_appearance" => include("name" => "Maya", "avatar_key" => "comet")))
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
    expect(Coworkers::ChatAgent.last.added_by_user).to eq(owner)

    expect {
      post "/api/v1/app/chats/#{chat.id}/agents/#{coworker.id}"
    }.not_to change(Coworkers::ChatAgent, :count)
    expect(response).to have_http_status(:created)

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

    get "/api/v1/app/coworkers/#{coworker.id}"

    chats = response.parsed_body.dig("coworker", "available_chats").index_by { |chat| chat.fetch("id") }
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

    get "/api/v1/app/coworkers/#{coworker.id}"

    traffic = response.parsed_body.dig("coworker", "message_traffic")
    expect(traffic).to include("sent" => 1, "received" => 1, "window_days" => 30)
    expect(traffic.fetch("delivery_events")).to contain_exactly(
      include("status" => "refused", "receiver_handle" => "rin", "reason" => "Message to @rin was not delivered")
    )
    expect(response.parsed_body.dig("coworker", "spend_usd")).to eq(1.25)
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

  it "triggers the exact roster-mentioned coworker in a group chat with the owner's settings" do
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

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Please ask @maya" } }
    }.to have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer)).once

    message = chat.messages.last
    expect(message.mentions).to contain_exactly(include("kind" => "coworker", "id" => maya.id, "handle" => "maya"))
    expect(message.mentions).not_to include(include("id" => mayank.id))
    expect(chat.reload).to be_turn_in_flight
    expect(Coworkers::TurnChatContext.new(chat, maya)).to have_attributes(
      coworker: maya, effective_chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
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

  it "uses one concurrency lane for back-to-back coworker mentions in the same group chat" do
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

    jobs = enqueued_jobs.select { |job| job.fetch(:job) == ChatTurnJob }
    expect(jobs.size).to eq(2)
    expect(jobs.map { |job| ChatTurnJob.new(*job.fetch(:args)).concurrency_key }.uniq)
      .to eq([ "#{ChatTurnJob::CONCURRENCY_GROUP}/chat:#{chat.id}" ])
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
    expect(chat).to have_attributes(
      repository: repository, chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
  end

  it "browses and searches the owner's coworker memory from the cached repository content surface" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: "coworkers/maya", files: {
      "memory/daily/2026-10-28.md" => "Yesterday's notes",
      "memory/daily/2026-10-29.md" => "Decided to ship the browser",
      "memory/people/thomas.md" => "Thomas likes evidence",
      "memory/repos/acme__app.md" => "Release checklist",
      "memory/banks/opinions.md" => "Search should be simple",
      "SOUL.md" => "not memory"
    })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/memory"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("files").pluck("path")).to eq([
      "memory/daily/2026-10-29.md", "memory/daily/2026-10-28.md", "memory/people/thomas.md",
      "memory/repos/acme__app.md", "memory/banks/opinions.md"
    ])

    get "/api/v1/app/coworkers/#{coworker.id}/memory", params: { search: "evidence" }
    expect(response.parsed_body.fetch("files")).to contain_exactly(include("path" => "memory/people/thomas.md", "content" => "Thomas likes evidence"))
  end

  it "distinguishes empty memory from an unreachable remote" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: "coworkers/maya", files: { "SOUL.md" => "role: Researcher" })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/memory"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("files")).to be_empty

    stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("offline"))
    get "/api/v1/app/coworkers/#{coworker.id}/memory"
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.dig("error", "code")).to eq("remote_unavailable")
  end

  it "marks searches incomplete when file contents or the provider tree are truncated" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
    content = ("a" * Coworkers::MemoryBrowser::MAX_FILE_BYTES) + "tail-only-needle"
    stub_repository_content(
      repository,
      ref: "coworkers/maya",
      files: { "memory/banks/long.md" => content },
      truncated_tree: true
    )
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/memory", params: { search: "tail-only-needle" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "files" => [], "truncated" => true, "partial" => true, "search_incomplete" => true
    )
  end

  it "returns a deliberate partial result when the memory tree exceeds the file bound" do
    stub_const("Coworkers::MemoryBrowser::MAX_FILES", 1)
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
    stub_repository_content(repository, ref: "coworkers/maya", files: {
      "memory/daily/2026-10-29.md" => "Today",
      "memory/people/thomas.md" => "Thomas"
    })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/memory"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("partial" => true, "search_incomplete" => false)
    expect(response.parsed_body.fetch("files").size).to eq(1)
  end

  it "does not expose another owner's memory browser" do
    other = Factories.user(email_address: "memory-owner@example.com")
    coworker = Coworkers::Coworker.create!(owner_user: other, name: "Hidden", handle: "hidden-memory", workspace_repo: "https://github.com/acme/private.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/memory"

    expect(response).to have_http_status(:not_found)
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

  it "removes the routes and sidebar contribution when the plugin is disabled" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: false)
    sign_in_as(owner)

    get "/api/v1/app/coworkers"
    expect(response).to have_http_status(:not_found)
    expect(Coworkers::SidebarPages.sidebar_pages).to be_present
    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).not_to include(Coworkers::SidebarPages)
  end
end
