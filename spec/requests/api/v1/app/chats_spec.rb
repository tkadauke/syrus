require "rails_helper"

RSpec.describe "API: /api/v1/app/chats", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/chats"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "accepts bearer-token authentication for CLI app API access" do
    user.update!(api_token: "cli-token")
    repository

    get "/api/v1/app/chats", headers: { "Authorization" => "Bearer cli-token" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["repositories"]).to contain_exactly(include("id" => repository.id, "slug" => "acme/widgets"))
  end

  describe "GET /api/v1/app/chats/new" do
    it "returns the repository from the most recently created chat session with one attached" do
      sign_in_as(user)
      older_repo = Factories.repository(user: user, owner: "acme", name: "aardvark")
      newer_repo = Factories.repository(user: user, owner: "acme", name: "zebra")

      older_chat = ChatSession.create!(user: user, repository: older_repo)
      older_chat.update_columns(created_at: 2.hours.ago)
      ChatSession.create!(user: user, repository: newer_repo)

      get "/api/v1/app/chats/new"

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("default_repository_id" => newer_repo.id)
    end

    it "falls back to alphabetical-first active repository when no chat session has a repository" do
      sign_in_as(user)
      ChatSession.create!(user: user)
      repo_a = Factories.repository(user: user, owner: "acme", name: "aardvark")
      Factories.repository(user: user, owner: "acme", name: "zebra")

      get "/api/v1/app/chats/new"

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("default_repository_id" => repo_a.id)
    end

    it "returns nil when the user has no repositories" do
      sign_in_as(user)

      get "/api/v1/app/chats/new"

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("default_repository_id" => nil)
    end
  end

  describe "sharing" do
    let(:chat_session) { ChatSession.create!(user: user, title: "Launch planning") }

    it "generates a stable share token and returns the shared URL" do
      sign_in_as(user)

      post "/api/v1/app/chats/#{chat_session.id}/share"

      expect(response).to have_http_status(:ok)
      first_token = chat_session.reload.share_token
      expect(first_token).to be_present
      expect(parse_body["share_url"]).to eq(shared_chat_url(token: first_token))

      post "/api/v1/app/chats/#{chat_session.id}/share"

      expect(response).to have_http_status(:ok)
      expect(chat_session.reload.share_token).to eq(first_token)
      expect(parse_body["share_url"]).to eq(shared_chat_url(token: first_token))
    end

    it "does not let another user create a share link for an owned chat" do
      sign_in_as(Factories.user)

      post "/api/v1/app/chats/#{chat_session.id}/share"

      expect(response).to have_http_status(:not_found)
      expect(chat_session.reload.share_token).to be_nil
    end

    it "lets another authenticated user read the shared message payload" do
      chat_session.update!(share_token: SecureRandom.uuid)
      chat_session.messages.create!(role: "user", content: { "text" => "Can you review the rollout?" })
      chat_session.messages.create!(role: "assistant", content: { "text" => "The rollout needs a staged deploy." })
      sign_in_as(Factories.user)

      get "/api/v1/app/shared_chats/#{chat_session.share_token}"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["chat"]).to include("id" => chat_session.id, "title" => "Launch planning")
      expect(body["messages"].map { |message| message["text"] }).to eq([
        "Can you review the rollout?",
        "The rollout needs a staged deploy."
      ])
      expect(body).not_to have_key("pending_actions")
      expect(body).not_to have_key("queued_messages")
      expect(body).not_to have_key("agent_questions")
    end

    it "requires authentication to read a shared chat" do
      chat_session.update!(share_token: SecureRandom.uuid)

      get "/api/v1/app/shared_chats/#{chat_session.share_token}"

      expect(response).to have_http_status(:unauthorized)
    end

    it "404s for unknown shared chat tokens" do
      sign_in_as(user)

      get "/api/v1/app/shared_chats/unknown-token"

      expect(response).to have_http_status(:not_found)
    end
  end

  it "branches a chat with copied messages, the same owner, provider setting, and a derived name" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Release planning", chat_provider: "claude", last_message_at: 1.hour.ago)
    chat.messages.create!(role: "user", content: { "text" => "Plan the launch." }, created_at: 2.hours.ago)
    chat.messages.create!(role: "assistant", content: { "text" => "Draft milestones." }, created_at: 90.minutes.ago)

    expect {
      post "/api/v1/app/chats/#{chat.id}/branch"
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(2)

    expect(response).to have_http_status(:created)
    branched = ChatSession.find(parse_body["id"])
    expect(parse_body["app_path"]).to eq(chat_path(branched))
    expect(branched.user).to eq(user)
    expect(branched.repository).to eq(repository)
    expect(branched.title).to eq("Release planning (branch)")
    expect(branched.chat_provider).to eq("claude")
    expect(branched.messages.count).to eq(chat.messages.count)
    expect(branched.messages.order(:created_at, :id).pluck(:role)).to eq(%w[user assistant])
    expect(branched.messages.order(:created_at, :id).map { |message| message.content["text"] })
      .to eq([ "Plan the launch.", "Draft milestones." ])
  end

  it "preserves a default provider setting when branching a chat" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Release planning", chat_provider: nil)

    post "/api/v1/app/chats/#{chat.id}/branch"

    expect(response).to have_http_status(:created)
    expect(ChatSession.find(parse_body["id"]).chat_provider).to be_nil
  end

  it "rejects branching another user's chat" do
    sign_in_as(user)
    other_user = Factories.user
    other_repository = Factories.repository(user: other_user, owner: "other", name: "repo")
    other_chat = ChatSession.create!(user: other_user, repository: other_repository, title: "Private")
    other_chat.messages.create!(role: "user", content: { "text" => "Private context." })

    expect {
      post "/api/v1/app/chats/#{other_chat.id}/branch"
    }.not_to change(ChatSession, :count)

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "lists recent chat groups and active repositories for CLI session picking" do
    sign_in_as(user)
    repository
    other_repo = Factories.repository(user: user, owner: "acme", name: "api")
    read_at = 3.hours.ago
    current_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Planning open source release",
      last_message_at: 2.hours.ago,
      last_read_at: read_at
    )
    older_chat = ChatSession.create!(
      user: user,
      repository: other_repo,
      title: "Auth refactor discussion",
      last_message_at: 1.day.ago,
      last_read_at: Time.current
    )
    current_chat.update_columns(created_at: 3.hours.ago, updated_at: current_chat.last_message_at)
    older_chat.update_columns(created_at: 2.days.ago, updated_at: older_chat.last_message_at)
    ChatSession.create!(user: Factories.user, title: "Foreign chat", last_message_at: Time.current)
    ChatProposal.create!(chat_session: current_chat, slug: "auth-map", title: "Map auth", body: "Trace auth.")
    ChatProposal.create!(chat_session: current_chat, slug: "auth-done", title: "Done auth", body: "Already handled.", state: "confirmed")
    ChatProposal.create!(chat_session: older_chat, slug: "api-map", title: "Map API", body: "Trace API.")

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["repositories"]).to contain_exactly(
      include("id" => repository.id, "slug" => "acme/widgets"),
      include("id" => other_repo.id, "slug" => "acme/api")
    )
    expect(body["groups"].map { |group| group["key"] }).to eq([ "repository-#{repository.id}", "repository-#{other_repo.id}" ])
    expect(body["groups"].first).to include(
      "key" => "repository-#{repository.id}",
      "label" => "acme/widgets",
      "repository_id" => repository.id,
      "has_more" => false
    )
    expect(body["groups"].first["chats"].map { |chat| chat["id"] }).to eq([ current_chat.id ])
    expect(body["groups"].first["chats"].first).to include(
      "title" => "Planning open source release",
      "repository" => include("id" => repository.id, "slug" => "acme/widgets"),
      "unread" => true,
      "pending_proposal_count" => 1
    )
    expect(body["groups"].second["chats"].first).to include("id" => older_chat.id, "unread" => false, "pending_proposal_count" => 1)
    expect(body["groups"].first["chats"].first["last_message_at"]).to be_present
    expect(body.to_s).not_to include("Foreign chat")
  end

  it "omits hidden chats from recent chat groups" do
    sign_in_as(user)
    visible_chat = ChatSession.create!(user: user, repository: repository, title: "Visible chat", last_message_at: 1.hour.ago)
    hidden_chat = ChatSession.create!(user: user, repository: repository, title: "Hidden chat", last_message_at: Time.current, hidden_at: 5.minutes.ago)

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }
    expect(group["chats"].map { |chat| chat["id"] }).to eq([ visible_chat.id ])
    expect(parse_body.to_s).not_to include(hidden_chat.title)
  end

  it "includes every repository chat group instead of only the global top twenty" do
    sign_in_as(user)
    old_repo = Factories.repository(user: user, owner: "acme", name: "old")

    20.times do |index|
      repo = Factories.repository(user: user, owner: "acme", name: "repo-#{index}")
      ChatSession.create!(user: user, repository: repo, title: "Recent #{index}", last_message_at: (index + 1).minutes.ago)
    end
    old_chat = ChatSession.create!(user: user, repository: old_repo, title: "Older repository chat", last_message_at: 2.days.ago)

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    body = parse_body
    old_group = body["groups"].find { |group| group["repository_id"] == old_repo.id }
    expect(old_group).to include("key" => "repository-#{old_repo.id}", "label" => "acme/old")
    expect(old_group["chats"].map { |chat| chat["id"] }).to eq([ old_chat.id ])
  end

  it "loads more chats for one sidebar group with a cursor" do
    sign_in_as(user)
    chats = 7.times.map do |index|
      chat = ChatSession.create!(
        user: user,
        repository: repository,
        title: "Chat #{index}",
        last_message_at: (index + 1).hours.ago
      )
      chat.update_columns(created_at: chat.last_message_at, updated_at: chat.last_message_at)
      chat
    end

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }
    expect(group["chats"].map { |chat| chat["id"] }).to eq(chats.first(5).map(&:id))
    expect(group["has_more"]).to eq(true)

    get "/api/v1/app/chats/more", params: { repository_id: repository.id, before_id: group["chats"].last["id"] }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["chats"].map { |chat| chat["id"] }).to eq(chats.last(2).map(&:id))
    expect(body["has_more"]).to eq(false)
  end

  it "orders pinned sidebar chats before unpinned chats in each group" do
    sign_in_as(user)
    unpinned_recent = ChatSession.create!(user: user, repository: repository, title: "Recent", last_message_at: 1.hour.ago)
    pinned_older = ChatSession.create!(user: user, repository: repository, title: "Pinned", pinned: true, last_message_at: 2.days.ago)

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }
    expect(group["chats"].map { |chat| chat["id"] }).to eq([ pinned_older.id, unpinned_recent.id ])
    expect(group["chats"].first["pinned"]).to eq(true)
  end

  it "toggles chat pinning for the owner only" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Plan")

    patch "/api/v1/app/chats/#{chat.id}", params: { chat: { pinned: true } }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.pinned?).to eq(true)
    expect(parse_body.dig("chat", "pinned")).to eq(true)

    patch "/api/v1/app/chats/#{chat.id}", params: { pinned: false }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.pinned?).to eq(false)

    other_user = Factories.user
    sign_in_as(other_user)
    patch "/api/v1/app/chats/#{chat.id}", params: { chat: { pinned: true } }

    expect(response).to have_http_status(:forbidden)
    expect(chat.reload.pinned?).to eq(false)
  end

  it "does not load hidden chats when paginating one sidebar group" do
    sign_in_as(user)
    chats = 7.times.map do |index|
      chat = ChatSession.create!(
        user: user,
        repository: repository,
        title: "Chat #{index}",
        last_message_at: (index + 1).hours.ago,
        hidden_at: index == 5 ? Time.current : nil
      )
      chat.update_columns(created_at: chat.last_message_at, updated_at: chat.last_message_at)
      chat
    end

    get "/api/v1/app/chats"
    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }

    get "/api/v1/app/chats/more", params: { repository_id: repository.id, before_id: group["chats"].last["id"] }

    expect(response).to have_http_status(:ok)
    expect(parse_body["chats"].map { |chat| chat["id"] }).to eq([ chats.last.id ])
  end

  describe "chat search" do
    before do
      allow(AppEvents).to receive(:broadcast)
      prepare_search_tables
      sign_in_as(user)
    end

    it "returns FTS-ranked chat results scoped to the current user" do
      weaker_chat = ChatSession.create!(user: user, repository: repository, title: "Weaker")
      stronger_chat = ChatSession.create!(user: user, repository: repository, title: "Stronger")
      other_user = Factories.user
      other_chat = ChatSession.create!(
        user: other_user,
        repository: Factories.repository(user: other_user),
        title: "Private"
      )

      create_indexed_message(weaker_chat, text: "needle deployment")
      stronger = create_indexed_message(stronger_chat, text: "needle needle needle deployment")
      create_indexed_message(other_chat, text: "needle needle needle private")

      get "/api/v1/app/chats/search", params: { q: "needle" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["total"]).to eq(2)
      expect(body["results"].map { |result| result["chat_session_id"] })
        .to eq([ stronger_chat.id, weaker_chat.id ])
      expect(body["results"].first).to include(
        "chat_title" => "Stronger",
        "best_match_message_id" => stronger.id,
        "total_match_count" => 1,
        "has_more_matches" => false
      )
      expect(body["results"].first["best_snippet"]).to include("<b>needle</b>")
      expect(body["results"].first["top_matches"]).to contain_exactly(
        include("message_id" => stronger.id, "role" => "assistant")
      )
    end

    it "omits hidden chats from search results" do
      visible_chat = ChatSession.create!(user: user, repository: repository, title: "Visible")
      hidden_chat = ChatSession.create!(user: user, repository: repository, title: "Hidden", hidden_at: Time.current)
      visible_message = create_indexed_message(visible_chat, text: "needle visible")
      create_indexed_message(hidden_chat, text: "needle hidden")

      get "/api/v1/app/chats/search", params: { q: "needle" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["results"]).to contain_exactly(
        include("chat_session_id" => visible_chat.id, "best_match_message_id" => visible_message.id)
      )
      expect(parse_body.to_s).not_to include("Hidden")
    end

    it "filters chats by attached epic without a text query" do
      epic = Factories.epic(user: user, repository: repository, title: "Search UI")
      matching = ChatSession.create!(
        user: user,
        repository: repository,
        title: "Matching",
        updated_at: 1.hour.ago
      )
      nonmatching = ChatSession.create!(
        user: user,
        repository: repository,
        title: "Other",
        updated_at: Time.current
      )
      matching.chat_attachments.create!(attachable: epic)

      get "/api/v1/app/chats/search", params: { epic_id: epic.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["total"]).to eq(1)
      expect(parse_body["results"]).to contain_exactly(
        include("chat_session_id" => matching.id, "chat_title" => "Matching", "top_matches" => [])
      )
      expect(parse_body.to_s).not_to include(nonmatching.title)
    end

    it "intersects text search results with attached epic filters" do
      epic = Factories.epic(user: user, repository: repository, title: "Search UI")
      matching = ChatSession.create!(user: user, repository: repository, title: "Matching")
      text_only = ChatSession.create!(user: user, repository: repository, title: "Text only")
      epic_only = ChatSession.create!(user: user, repository: repository, title: "Epic only")
      matching.chat_attachments.create!(attachable: epic)
      epic_only.chat_attachments.create!(attachable: epic)
      message = create_indexed_message(matching, text: "needle in attached chat")
      create_indexed_message(text_only, text: "needle in detached chat")

      get "/api/v1/app/chats/search", params: { q: "needle", epic_id: epic.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["total"]).to eq(1)
      expect(parse_body["results"]).to contain_exactly(
        include("chat_session_id" => matching.id, "best_match_message_id" => message.id)
      )
      expect(parse_body.to_s).not_to include(text_only.title)
      expect(parse_body.to_s).not_to include(epic_only.title)
    end

    it "returns an empty result payload when nothing matches" do
      get "/api/v1/app/chats/search", params: { q: "missing" }

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("results" => [], "total" => 0)
    end

    it "returns all matching messages for a chat and query" do
      chat = ChatSession.create!(user: user, repository: repository, title: "Memory")
      first = create_indexed_message(chat, text: "needle first", role: "user")
      second = create_indexed_message(chat, text: "needle second", role: "assistant")

      get "/api/v1/app/chats/search/messages", params: { chat_session_id: chat.id, q: "needle" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["matches"].map { |match| match["message_id"] })
        .to contain_exactly(first.id, second.id)
      expect(parse_body["matches"]).to all(include("snippet", "role", "created_at"))
    end

    it "does not expand message search for hidden chats" do
      chat = ChatSession.create!(user: user, repository: repository, title: "Memory", hidden_at: Time.current)
      create_indexed_message(chat, text: "needle hidden")

      get "/api/v1/app/chats/search/messages", params: { chat_session_id: chat.id, q: "needle" }

      expect(response).to have_http_status(:not_found)
    end

    it "never returns another user's chats from search or expansion" do
      other_user = Factories.user
      other_chat = ChatSession.create!(
        user: other_user,
        repository: Factories.repository(user: other_user),
        title: "Private"
      )
      create_indexed_message(other_chat, text: "needle private")

      get "/api/v1/app/chats/search", params: { q: "needle" }

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("results" => [], "total" => 0)

      get "/api/v1/app/chats/search/messages", params: { chat_session_id: other_chat.id, q: "needle" }

      expect(response).to have_http_status(:not_found)
    end
  end

  it "marks a chat read for the signed-in user" do
    sign_in_as(user)
    newer_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Newer chat",
      last_message_at: 1.hour.ago
    )
    chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Older chat",
      last_message_at: 1.day.ago,
      last_read_at: nil
    )
    chat.update_columns(created_at: 2.days.ago, updated_at: chat.last_message_at)
    newer_chat.update_columns(created_at: 2.hours.ago, updated_at: newer_chat.last_message_at)
    original_updated_at = chat.reload.updated_at
    foreign_chat = ChatSession.create!(user: Factories.user, last_message_at: Time.current, last_read_at: nil)

    patch "/api/v1/app/chats/#{chat.id}/mark_read"

    expect(response).to have_http_status(:no_content)
    expect(chat.reload.last_read_at).to be_present
    expect(chat.updated_at.to_i).to eq(original_updated_at.to_i)
    expect(foreign_chat.reload.last_read_at).to be_nil

    get "/api/v1/app/chats"

    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }
    expect(group["chats"].map { |candidate| candidate.fetch("id") }).to eq([ newer_chat.id, chat.id ])
  end

  it "hides and restores a chat for the signed-in user" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Planning", last_message_at: Time.current)

    patch "/api/v1/app/chats/#{chat.id}/hide"

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Chat hidden.")
    expect(chat.reload.hidden_at).to be_present

    patch "/api/v1/app/chats/#{chat.id}/unhide"

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Chat restored.")
    expect(chat.reload.hidden_at).to be_nil
  end

  it "lists hidden chats for recovery in hidden order" do
    sign_in_as(user)
    older = ChatSession.create!(user: user, repository: repository, title: "Older", hidden_at: 2.days.ago)
    newer = ChatSession.create!(user: user, title: "Newer", hidden_at: 1.hour.ago)
    ChatSession.create!(user: user, title: "Visible")
    ChatSession.create!(user: Factories.user, title: "Foreign", hidden_at: Time.current)

    get "/api/v1/app/settings/hidden_chats"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["chats"].map { |chat| chat["id"] }).to eq([ newer.id, older.id ])
    expect(body["chats"].first).to include(
      "title" => "Newer",
      "repository" => nil,
      "hidden_at" => newer.hidden_at.iso8601,
      "app_unhide_path" => "/api/v1/app/chats/#{newer.id}/unhide"
    )
    expect(body["chats"].second["repository"]).to include("slug" => "acme/widgets")
    expect(body).to include("total" => 2, "page" => 1, "per_page" => 20, "total_pages" => 1)
    expect(body.to_s).not_to include("Visible")
    expect(body.to_s).not_to include("Foreign")
  end

  it "renames a chat for the signed-in user" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Old title", last_message_at: Time.current)

    post "/api/v1/app/chats/#{chat.id}/rename", params: { name: "  Release planning  " }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.title).to eq("Release planning")
    expect(parse_body["message"]).to eq("Chat renamed.")
    expect(parse_body.dig("chat", "title")).to eq("Release planning")
  end

  it "rejects invalid chat rename names" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Old title", last_message_at: Time.current)

    post "/api/v1/app/chats/#{chat.id}/rename", params: { name: " " }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Name cannot be blank.")
    expect(chat.reload.title).to eq("Old title")

    post "/api/v1/app/chats/#{chat.id}/rename", params: { name: "a" * (ChatSession::TITLE_MAX_LENGTH + 1) }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Name must be #{ChatSession::TITLE_MAX_LENGTH} characters or fewer.")
    expect(chat.reload.title).to eq("Old title")
  end

  it "creates a fresh chat with an optional repository attachment" do
    sign_in_as(user)
    user.update!(agent_provider: "codex", chat_provider: "claude")

    expect {
      post "/api/v1/app/chats", params: { repository_id: repository.id }
    }.to change(ChatSession, :count).by(1)

    expect(response).to have_http_status(:created)
    chat = ChatSession.last
    expect(chat.user).to eq(user)
    expect(chat.chat_provider).to be_nil
    expect(chat.effective_chat_provider).to eq("claude")
    expect(chat.title).to be_nil
    expect(chat).not_to be_title_pending
    expect(chat.attached_repositories).to contain_exactly(repository)
    expect(parse_body).to include("message" => "Chat created.", "redirect_to" => chat_path(chat))
    expect(parse_body.dig("chat", "title")).to eq("widgets")
    expect(parse_body.dig("chat", "title_pending")).to eq(false)
    expect(parse_body.dig("chat", "repository", "slug")).to eq("acme/widgets")
    expect(parse_body.dig("chat", "chat_provider")).to be_nil
    expect(parse_body.dig("chat", "effective_chat_provider")).to eq("claude")
  end

  it "creates an empty chat session without a first message" do
    sign_in_as(user)
    user.update!(chat_provider: "claude")

    expect {
      post "/api/v1/app/chats"
    }.to change(ChatSession, :count).by(1)

    expect(response).to have_http_status(:created)
    chat = ChatSession.last
    expect(chat.user).to eq(user)
    expect(chat.chat_provider).to be_nil
    expect(chat.effective_chat_provider).to eq("claude")
    expect(chat.repository).to be_nil
    expect(chat.last_message_at).to be_nil
    expect(chat.messages).to be_empty
    expect(ChatMessage.count).to eq(0)
    expect(enqueued_jobs).to be_empty
    expect(parse_body).to include("message" => "Chat created.", "redirect_to" => chat_path(chat))
  end

  it "updates a chat provider setting to default or a configured explicit provider" do
    sign_in_as(user)
    user.update!(codex_api_key: "sk-test")
    chat = ChatSession.create!(user: user, repository: repository)

    patch "/api/v1/app/chats/#{chat.id}", params: { chat: { chat_provider: "codex" } }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.chat_provider).to eq("codex")
    expect(parse_body.dig("chat", "chat_provider")).to eq("codex")
    expect(parse_body.dig("chat", "effective_chat_provider")).to eq("codex")
    expect(parse_body.dig("chat", "chat_provider_options")).to include(
      include("value" => nil, "label" => "Default", "configured" => true),
      include("value" => "claude", "label" => "Claude", "configured" => true),
      include("value" => "codex", "label" => "Codex", "configured" => true)
    )

    patch "/api/v1/app/chats/#{chat.id}", params: { chat: { chat_provider: "" } }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.chat_provider).to be_nil
    expect(parse_body.dig("chat", "chat_provider")).to be_nil
  end

  it "rejects unknown or unconfigured explicit chat providers" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository)

    patch "/api/v1/app/chats/#{chat.id}", params: { chat: { chat_provider: "codex" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Chat provider is not configured.")
    expect(chat.reload.chat_provider).to be_nil

    patch "/api/v1/app/chats/#{chat.id}", params: { chat: { chat_provider: "oracle" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Chat provider is not configured.")
    expect(chat.reload.chat_provider).to be_nil
  end

  it "enqueues title generation when an unstarted chat receives its first message" do
    sign_in_as(user)

    post "/api/v1/app/chats", params: { repository_id: repository.id }
    chat = ChatSession.last

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Build the calendar" } }
    }.to change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTitleJob).with(chat.id, kind_of(Integer))
      .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

    expect(response).to have_http_status(:ok)
    expect(chat.reload.title).to be_nil
    expect(chat).to be_title_pending
    expect(parse_body.dig("chat", "title")).to eq("widgets")
    expect(parse_body.dig("chat", "title_pending")).to eq(true)
  end

  it "creates the onboarding chat attached to the first repository, seeded and flagged" do
    sign_in_as(user)
    user.update!(agent_provider: "codex", chat_provider: "claude")
    repository

    expect {
      post "/api/v1/app/chats/onboarding"
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTurnJob)

    expect(response).to have_http_status(:created)
    chat = ChatSession.last
    expect(chat.onboarding?).to be true
    expect(chat.chat_provider).to be_nil
    expect(chat.effective_chat_provider).to eq("claude")
    expect(chat.repository).to eq(repository)
    expect(chat.messages.last.role).to eq("user")
    expect(chat.messages.last.content["text"]).to include("setting up Syrus")
    expect(parse_body).to include("redirect_to" => chat_path(chat))
  end

  it "creates the onboarding chat even with no repository yet" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/chats/onboarding"
    }.to change(ChatSession, :count).by(1)

    expect(ChatSession.last.repository).to be_nil
    expect(ChatSession.last.onboarding?).to be true
  end

  it "is idempotent — a second onboarding request returns the existing chat" do
    sign_in_as(user)
    repository
    post "/api/v1/app/chats/onboarding"
    existing = ChatSession.last

    expect {
      post "/api/v1/app/chats/onboarding"
    }.not_to change(ChatSession, :count)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("redirect_to" => chat_path(existing))
  end

  it "does not create a chat with an archived repository attachment" do
    sign_in_as(user)
    repository.archive!

    expect {
      post "/api/v1/app/chats", params: { repository_id: repository.id }
    }.not_to change(ChatSession, :count)

    expect(response).to have_http_status(:not_found)
  end

  it "creates the first message and enqueues a turn" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/chats", params: { repository_id: repository.id, chat_message: { text: "Map auth" } }
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTitleJob)
      .and have_enqueued_job(ChatTurnJob)

    chat = ChatSession.last
    expect(chat.title).to be_nil
    expect(chat).to be_title_pending
    expect(chat.messages.last.content).to eq("text" => "Map auth")
    expect(parse_body).to include("message" => "Message sent.", "redirect_to" => chat_path(chat))
    expect(parse_body.dig("chat", "title_pending")).to eq(true)
  end

  it "stores valid file attachments on the first chat message" do
    sign_in_as(user)
    attachment = {
      name: "aqueduct.png",
      mime_type: "image/png",
      data: Base64.strict_encode64("image-bytes"),
      ignored: "drop me"
    }

    post "/api/v1/app/chats", params: {
      repository_id: repository.id,
      chat_message: {
        text: "Inspect this image",
        attachments: [ attachment ]
      }
    }

    expect(response).to have_http_status(:created)
    expect(ChatSession.last.messages.last.content).to eq(
      "text" => "Inspect this image",
      "attachments" => [
        {
          "name" => "aqueduct.png",
          "mime_type" => "image/png",
          "data" => Base64.strict_encode64("image-bytes")
        }
      ]
    )
  end

  it "starts the first-message chat with a pending generated title" do
    sign_in_as(user)

    post "/api/v1/app/chats", params: {
      repository_id: repository.id,
      chat_message: {
        text: "Please build a habit tracker with streaks and calendar heatmaps, and make it work on mobile"
      }
    }

    expect(response).to have_http_status(:created)
    chat = ChatSession.last
    expect(chat.title).to be_nil
    expect(chat).to be_title_pending
    expect(parse_body.dig("chat", "title")).to eq("widgets")
    expect(parse_body.dig("chat", "title_pending")).to eq(true)
    expect(ChatTitleJob).to have_been_enqueued.with(chat.id, chat.messages.last.id)
  end

  it "retries a transient Solid Queue lock when creating the first turn" do
    sign_in_as(user)
    stub_const("Api::V1::App::ChatsController::CHAT_TURN_ENQUEUE_RETRY_DELAYS", [ 0 ])
    enqueue_attempts = 0
    lock_error = SolidQueue::Job::EnqueueError.new("ActiveRecord::StatementTimeout: SQLite3::BusyException: database is locked")

    allow(ChatTurnJob).to receive(:perform_later).and_wrap_original do |method, *args, **kwargs|
      enqueue_attempts += 1
      raise lock_error if enqueue_attempts == 1

      method.call(*args, **kwargs)
    end

    expect {
      post "/api/v1/app/chats", params: { repository_id: repository.id, chat_message: { text: "Map auth" } }
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTitleJob)
      .and have_enqueued_job(ChatTurnJob)

    expect(response).to have_http_status(:created)
    expect(enqueue_attempts).to eq(2)
  end

  it "creates a chat without a repository attachment" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/chats", params: { chat_message: { text: "Map tkadauke/syrus" } }
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTurnJob)

    chat = ChatSession.last
    expect(chat.attached_repositories).to be_empty
    expect(chat.title).to be_nil
    expect(chat.messages.last.content).to eq("text" => "Map tkadauke/syrus")
  end

  it "returns the chat data payload with raw messages" do
    sign_in_as(user)
    document = repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Launch notes",
      google_docs_url: "https://docs.google.com/document/d/launch/edit"
    )
    chat = ChatSession.create!(
      user: user,
      repository: repository,
      cumulative_input_tokens: 12_400,
      cumulative_output_tokens: 3_200,
      cumulative_cost_usd: 0.012345,
      last_message_at: Time.current
    )
    older_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Older chat",
      last_message_at: 2.days.ago
    )
    ChatSession.create!(user: Factories.user, title: "Foreign chat", last_message_at: Time.current)
    message = chat.messages.create!(role: "assistant", content: { "text" => "Discuss **aqueducts**." })
    message.bookmarks.create!(label: "Aqueducts", kind: "topic")
    question = chat.agent_questions.create!(question: "Which path?", options: [ "Fast", "Careful" ], asked_at: Time.current)
    chat.create_whiteboard!(
      scene_json: {
        "elements" => [ { "id" => "box-1", "type" => "rectangle" } ],
        "appState" => { "viewBackgroundColor" => "#ffffff" },
        "files" => { "file-1" => { "id" => "file-1", "dataURL" => "data:image/png;base64,abc" } }
      },
      version: 2
    )

    get "/api/v1/app/chats/#{chat.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("chat", "repository", "slug")).to eq("acme/widgets")
    expect(body.dig("chat", "cumulative_input_tokens")).to eq(12_400)
    expect(body.dig("chat", "turn_in_flight")).to eq(false)
    expect(body.dig("chat", "agent_busy")).to eq(false)
    expect(body["chat_available"]).to eq(true)
    expect(body["turn_in_flight"]).to eq(false)
    expect(body["agent_busy"]).to eq(false)
    expect(body["bookmarks"]).to contain_exactly(include("label" => "Aqueducts", "chat_message_id" => message.id, "anchor_message_id" => message.id))
    expect(body["agent_questions"]).to contain_exactly(include(
      "id" => question.id,
      "question" => "Which path?",
      "options" => [ "Fast", "Careful" ],
      "app_answer_path" => "/api/v1/app/chats/#{chat.id}/agent_questions/#{question.id}/answer"
    ))
    expect(body["recent_chats"]).to include(
      include("id" => chat.id, "current" => true, "chat_path" => chat_path(chat), "repository" => include("slug" => "acme/widgets")),
      include("id" => older_chat.id, "current" => false, "title" => "Older chat")
    )
    expect(body["recent_chats"].to_s).not_to include("Foreign chat")
    expect(body["messages"]).to contain_exactly(include(
      "type" => "message",
      "id" => message.id,
      "role" => "assistant",
      "tool_name" => nil,
      "content" => { "text" => "Discuss **aqueducts**." },
      "text" => "Discuss **aqueducts**."
    ))
    expect(body["messages"].first).not_to have_key("html")
    expect(body["messages"].first).not_to have_key("bookmark_path")
    expect(body["documents_in_scope"]).to contain_exactly(include("title" => document.title, "repository_slug" => "acme/widgets"))
    expect(body.dig("whiteboard", "version")).to eq(2)
    expect(body.dig("whiteboard", "elements", 0, "id")).to eq("box-1")
    expect(body.dig("whiteboard", "appState")).to eq("viewBackgroundColor" => "#ffffff")
    expect(body.dig("whiteboard", "files", "file-1", "dataURL")).to eq("data:image/png;base64,abc")
    expect(body.dig("paths", "app_messages_path")).to eq("/api/v1/app/chats/#{chat.id}/messages")
    expect(body.dig("paths", "app_message_path")).to eq("/api/v1/app/chats/#{chat.id}/message")
    expect(body.dig("paths", "app_rename_path")).to eq("/api/v1/app/chats/#{chat.id}/rename")
    expect(body.dig("paths", "app_clear_path")).to eq("/api/v1/app/chats/#{chat.id}/messages")
    expect(body.dig("paths", "app_enqueue_message_path")).to eq("/api/v1/app/chats/#{chat.id}/queued_messages")
    expect(body.dig("paths", "app_rename_path")).to eq("/api/v1/app/chats/#{chat.id}/rename")
    expect(body.dig("paths", "app_attachments_path")).to eq("/api/v1/app/chats/#{chat.id}/attachments")
    expect(body.dig("paths", "app_whiteboard_path")).to eq("/api/v1/app/chats/#{chat.id}/whiteboard")
    expect(body["queued_messages"]).to eq([])
    expect(body["paths"].keys).not_to include("chat_messages_path", "chat_attachments_path", "chat_whiteboard_path")
  end

  it "answers an active agent question" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    question = chat.agent_questions.create!(question: "Which branch?", options: [ "main", "release" ], asked_at: Time.current)

    post "/api/v1/app/chats/#{chat.id}/agent_questions/#{question.id}/answer", params: { answer: "release" }

    expect(response).to have_http_status(:ok)
    expect(question.reload.answer).to eq("release")
    expect(question.answered_at).to be_present
    expect(chat.messages.order(:created_at, :id).last).to have_attributes(
      role: "user",
      content: { "text" => "release" }
    )
    expect(parse_body["agent_questions"]).to eq([])
    expect(parse_body["messages"]).to include(include(
      "role" => "user",
      "text" => "release"
    ))
  end

  it "rejects blank or inactive agent question answers" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    question = chat.agent_questions.create!(question: "Continue?", asked_at: Time.current)

    post "/api/v1/app/chats/#{chat.id}/agent_questions/#{question.id}/answer", params: { answer: " " }

    expect(response).to have_http_status(:unprocessable_content)
    expect(question.reload.answer).to be_nil

    question.expire!
    post "/api/v1/app/chats/#{chat.id}/agent_questions/#{question.id}/answer", params: { answer: "yes" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(question.reload.answer).to be_nil
  end

  it "queues, edits, and deletes a message while a chat turn is active" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    chat.messages.create!(role: "user", content: { "text" => "Start mapping" })
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )

    expect {
      post "/api/v1/app/chats/#{chat.id}/queued_messages", params: { chat_message: { text: "Inspect the aqueducts" } }
    }.to change(ChatQueuedMessage, :count).by(1)
    expect(ChatMessage.count).to eq(1)
    expect(ChatTurnJob).not_to have_been_enqueued

    expect(response).to have_http_status(:ok)
    queued_message = chat.chat_queued_messages.last
    expect(parse_body["message"]).to eq("Message queued.")
    expect(parse_body["queued_messages"]).to contain_exactly(include(
      "id" => queued_message.id,
      "text" => "Inspect the aqueducts",
      "app_update_path" => "/api/v1/app/chats/#{chat.id}/queued_messages/#{queued_message.id}",
      "app_delete_path" => "/api/v1/app/chats/#{chat.id}/queued_messages/#{queued_message.id}"
    ))

    patch "/api/v1/app/chats/#{chat.id}/queued_messages/#{queued_message.id}", params: { chat_message: { text: "Inspect the forum" } }

    expect(response).to have_http_status(:ok)
    expect(queued_message.reload.text).to eq("Inspect the forum")
    expect(parse_body["queued_messages"]).to contain_exactly(include("id" => queued_message.id, "text" => "Inspect the forum"))

    expect {
      delete "/api/v1/app/chats/#{chat.id}/queued_messages/#{queued_message.id}"
    }.to change { chat.reload.queued_messages.count }.from(1).to(0)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Queued message deleted.")
    expect(parse_body["queued_messages"]).to eq([])
  end

  it "stores valid file attachments on a queued chat message" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    chat.messages.create!(role: "user", content: { "text" => "Start mapping" })
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )
    attachment = {
      name: "brief.pdf",
      mime_type: "application/pdf",
      data: Base64.strict_encode64("%PDF-1.7"),
      ignored: "drop me"
    }

    expect {
      post "/api/v1/app/chats/#{chat.id}/queued_messages", params: {
        chat_message: {
          text: "Inspect the brief",
          attachments: [ attachment ]
        }
      }
    }.to change(ChatQueuedMessage, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(chat.reload.chat_queued_messages.last.content).to eq(
      "text" => "Inspect the brief",
      "attachments" => [
        {
          "name" => "brief.pdf",
          "mime_type" => "application/pdf",
          "data" => Base64.strict_encode64("%PDF-1.7")
        }
      ]
    )
  end

  it "sends a queued-message request immediately when the chat is idle" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)

    expect {
      post "/api/v1/app/chats/#{chat.id}/queued_messages", params: { chat_message: { text: "Start now" } }
    }.to change(ChatQueuedMessage, :count).by(1)
      .and change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTurnJob)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Message sent.")
    expect(chat.reload.queued_messages).to be_empty
    expect(chat.chat_queued_messages.last.delivered_at).to be_present
    expect(chat.messages.last.content).to eq("text" => "Start now")
  end

  it "does not return another user's private chat payload or messages" do
    sign_in_as(user)
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
    other_chat = ChatSession.create!(user: other_user, repository: other_repo, title: "Private chat")
    other_chat.messages.create!(role: "user", content: { "text" => "Private message" })
    other_chat.create_whiteboard!(
      scene_json: { "elements" => [ { "id" => "private-box" } ], "appState" => {}, "files" => {} },
      version: 1
    )

    get "/api/v1/app/chats/#{other_chat.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include("Private chat")
    expect(response.body).not_to include("Private message")
    expect(response.body).not_to include("private-box")

    get "/api/v1/app/chats/#{other_chat.id}/messages"

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include("Private message")
  end

  it "resolves bookmark anchors to rendered chat messages" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    chat.messages.create!(role: "assistant", content: { "text" => "Preparing an epic." })
    tool_message = chat.messages.create!(
      role: "tool_use",
      tool_name: "mcp__syrus-chat-sidecar__set_bookmark",
      content: { "name" => "mcp__syrus-chat-sidecar__set_bookmark", "input" => { "label" => "Wisdom App Epic", "kind" => "epic_origin" } }
    )
    proposal_message = chat.messages.create!(role: "assistant", content: { "text" => "Epic proposal proposed." })
    tool_message.bookmarks.create!(label: "Wisdom App Epic", kind: "epic_origin")

    get "/api/v1/app/chats/#{chat.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["bookmarks"]).to contain_exactly(
      include(
        "label" => "Wisdom App Epic",
        "chat_message_id" => tool_message.id,
        "anchor_message_id" => proposal_message.id
      )
    )
  end

  it "orders the chat navigation by recent activity" do
    sign_in_as(user)
    current_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Old but active",
      created_at: 3.days.ago,
      updated_at: 3.days.ago,
      last_message_at: Time.current
    )
    middle_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Middle",
      created_at: 2.days.ago,
      updated_at: 2.days.ago,
      last_message_at: 12.hours.ago,
      last_read_at: Time.current
    )
    newest_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Newest",
      created_at: 1.day.ago,
      updated_at: 1.day.ago,
      last_message_at: nil
    )

    get "/api/v1/app/chats/#{current_chat.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["recent_chats"].map { |chat| chat.fetch("id") }).to eq([ current_chat.id, middle_chat.id, newest_chat.id ])
    expect(body["recent_chats"].map { |chat| chat.fetch("current") }).to eq([ true, false, false ])
    expect(body["recent_chats"].map { |chat| chat.fetch("unread") }).to eq([ true, false, false ])
  end

  it "orders recent chats by last_message_at, ignoring updated_at bumps" do
    sign_in_as(user)
    recent_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Recent",
      created_at: 2.days.ago,
      updated_at: 2.days.ago,
      last_message_at: 1.hour.ago
    )
    older_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Older",
      created_at: 3.days.ago,
      updated_at: 3.days.ago,
      last_message_at: 1.day.ago
    )

    older_chat.touch

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }
    expect(group["chats"].map { |chat| chat.fetch("id") }).to start_with(recent_chat.id, older_chat.id)
  end

  it "does not reorder chats when a non-message operation bumps updated_at" do
    sign_in_as(user)
    messaged_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Recent messages",
      created_at: 2.days.ago,
      updated_at: 2.days.ago,
      last_message_at: 1.hour.ago
    )
    renamed_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Old chat",
      created_at: 3.days.ago,
      updated_at: 3.days.ago,
      last_message_at: 1.day.ago
    )

    renamed_chat.update_columns(updated_at: Time.current)

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }
    expect(group["chats"].map { |chat| chat.fetch("id") }).to start_with(messaged_chat.id, renamed_chat.id)
  end

  it "uses created_at as the sort key for chats without messages" do
    sign_in_as(user)
    messaged_chat = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Has messages",
      last_message_at: 2.hours.ago
    )
    recent_messageless = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Recent, no messages",
      last_message_at: nil
    )
    recent_messageless.update_columns(created_at: 1.hour.ago)
    old_messageless = ChatSession.create!(
      user: user,
      repository: repository,
      title: "Old, no messages",
      last_message_at: nil
    )
    old_messageless.update_columns(created_at: 4.hours.ago)

    get "/api/v1/app/chats"

    expect(response).to have_http_status(:ok)
    group = parse_body["groups"].find { |candidate| candidate["repository_id"] == repository.id }
    chat_ids = group["chats"].map { |chat| chat.fetch("id") }
    expect(chat_ids).to eq([ recent_messageless.id, messaged_chat.id, old_messageless.id ])
  end

  it "reports a running chat agent process in the app payload" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )

    get "/api/v1/app/chats/#{chat.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["agent_busy"]).to eq(true)
  end

  it "returns older messages as typed JSON for frontend rendering" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    messages = 40.times.map { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

    get "/api/v1/app/chats/#{chat.id}/messages", params: { before: messages[30].id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["has_more_older"]).to eq(false)
    expect(body["messages"].map { |message| message.fetch("id") }).to eq(messages.first(30).map(&:id))
    expect(body["messages"].first).to include(
      "type" => "message",
      "role" => "user",
      "content" => { "text" => "msg-0" },
      "text" => "msg-0"
    )
    expect(body["messages"].first).not_to have_key("html")
  end

  it "forces the cursor index for MySQL chat message pagination" do
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    controller = Api::V1::App::ChatsController.new

    allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Mysql2")

    sql = controller.send(:message_scope, chat).where("id < ?", 123).order(id: :desc).limit(31).to_sql

    expect(sql).to include("FORCE INDEX (index_chat_messages_on_session_id_and_id)")
  end

  it "keeps proposal bodies as text instead of pre-rendered HTML" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = ChatProposal.create!(
      chat_session: chat,
      slug: "auth-map",
      title: "Map auth flow",
      body: "Trace **auth** and `<script>`."
    )
    chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

    get "/api/v1/app/chats/#{chat.id}"

    proposal_payload = parse_body["messages"].first.fetch("proposal")
    expect(proposal_payload).to include("body" => "Trace **auth** and `<script>`.")
    expect(proposal_payload).not_to have_key("body_html")
  end

  it "updates a proposed proposal title, body, and dependencies" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = ChatProposal.create!(chat_session: chat, slug: "build-ui", title: "Build UI", body: "Old body.")
    old_dependency = ChatProposal.create!(chat_session: chat, slug: "old-api", title: "Old API", body: "Old dependency.")
    new_dependency = ChatProposal.create!(chat_session: chat, slug: "new-api", title: "New API", body: "New dependency.")
    ChatProposalDependency.create!(proposal: proposal, depends_on: old_dependency)
    job_dependency = Factories.job(repository: repository, issue_title: "Existing Job")
    epic_dependency = Factories.epic(user: user, repository: repository, title: "Existing Epic")
    chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

    patch "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}", params: {
      proposal: {
        title: "Build better UI",
        body: "New body.",
        dependency_slugs: [ new_dependency.slug ],
        depends_on_job_ids: [ job_dependency.id ],
        depends_on_epic_ids: [ epic_dependency.id ]
      }
    }

    expect(response).to have_http_status(:ok)
    proposal.reload
    expect(proposal.title).to eq("Build better UI")
    expect(proposal.body).to eq("New body.")
    expect(proposal.dependencies).to contain_exactly(new_dependency)
    expect(proposal.depends_on_job_ids).to eq([ job_dependency.id ])
    expect(proposal.depends_on_epic_ids).to eq([ epic_dependency.id ])
    expect(proposal.edited_at).to be_present
    expect(parse_body.dig("proposal", "title")).to eq("Build better UI")
    expect(parse_body.dig("proposal", "depends_on_job_ids")).to eq([ job_dependency.id ])
    expect(parse_body.dig("message")).to eq("Proposal updated.")
  end

  it "rejects updates to confirmed proposals" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = ChatProposal.create!(chat_session: chat, slug: "build-ui", title: "Build UI", body: "Body.", state: "confirmed")

    patch "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}", params: {
      proposal: { title: "Updated", body: "Body.", dependency_slugs: [] }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Proposal is no longer proposed.")
    expect(proposal.reload.title).to eq("Build UI")
  end

  it "does not allow another user to update a proposal" do
    sign_in_as(Factories.user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = ChatProposal.create!(chat_session: chat, slug: "build-ui", title: "Build UI", body: "Body.")

    patch "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}", params: {
      proposal: { title: "Updated", body: "Body.", dependency_slugs: [] }
    }

    expect(response).to have_http_status(:not_found)
  end

  it "searches proposals in the current chat and excludes the edited proposal" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    editing = ChatProposal.create!(chat_session: chat, slug: "api-map", title: "Map API", body: "Editing.")
    match = ChatProposal.create!(chat_session: chat, slug: "api-build", title: "Build API", body: "Match.")
    ChatProposal.create!(chat_session: chat, slug: "ui-build", title: "Build UI", body: "No match.")
    other_chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    ChatProposal.create!(chat_session: other_chat, slug: "api-other", title: "Other API", body: "Wrong chat.")

    get "/api/v1/app/chats/#{chat.id}/proposals/search", params: { q: "api", exclude_id: editing.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("proposals")).to contain_exactly(
      include("id" => match.id, "slug" => "api-build", "title" => "Build API")
    )
  end

  it "returns tool calls as raw chronological messages for frontend rendering" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    first_call = chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "a.py" } })
    first_result = chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "first" } ] })
    second_call = chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "b.py" } })
    second_result = chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "second" } ] })

    get "/api/v1/app/chats/#{chat.id}"

    expect(parse_body["messages"].map { |message| message.fetch("id") }).to eq(
      [ first_call.id, first_result.id, second_call.id, second_result.id ]
    )
    expect(parse_body["messages"].first).to include(
      "type" => "message",
      "role" => "tool_use",
      "tool_name" => "Read",
      "content" => { "input" => { "file_path" => "a.py" } }
    )
    expect(parse_body["messages"].second).to include(
      "type" => "message",
      "role" => "tool_result",
      "tool_name" => "Read",
      "content" => { "result" => [ { "type" => "text", "text" => "first" } ] }
    )
  end

  it "returns raw system messages and proposal card data" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = ChatProposal.create!(
      chat_session: chat,
      slug: "auth-map",
      title: "Map auth flow",
      body: "Trace the auth flow."
    )
    chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })
    chat.messages.create!(
      role: "system",
      content: {
        "text" => "[result] subtype=success, is_error=false, turns=4, duration_ms=170223, total_cost_usd=0.37236969999999997"
      }
    )

    get "/api/v1/app/chats/#{chat.id}"

    proposal_message = parse_body["messages"].first
    expect(proposal_message.dig("proposal", "title")).to eq("Map auth flow")
    expect(proposal_message.dig("proposal")).not_to have_key("confirm_path")
    expect(proposal_message.dig("proposal")).not_to have_key("reject_path")
    expect(proposal_message.dig("proposal", "app_confirm_path")).to eq("/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}/confirm")
    system_message = parse_body["messages"].second
    expect(system_message).to include(
      "role" => "system",
      "content" => { "text" => "[result] subtype=success, is_error=false, turns=4, duration_ms=170223, total_cost_usd=0.37236969999999997" }
    )
    expect(system_message).not_to have_key("system")
  end

  it "returns the Epic detail path for confirmed Epic proposals" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    epic = Factories.epic(user: user, repository: repository, title: "Raise the forum")
    proposal = ChatProposal.create!(
      chat_session: chat,
      repository: repository,
      epic: epic,
      kind: "epic",
      state: "confirmed",
      slug: "raise-the-forum",
      title: "Raise the forum",
      body: "Let the forum stand."
    )
    chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Epic proposal confirmed." })

    get "/api/v1/app/chats/#{chat.id}"

    proposal_payload = parse_body["messages"].first.fetch("proposal")
    expect(proposal_payload["materialized_label"]).to eq(epic.slug)
    expect(proposal_payload["materialized_path"]).to eq("/epics/#{epic.id}")
    # Epic state + state-change path so the chat can offer a "Start" action.
    expect(proposal_payload["materialized_epic_state"]).to eq(epic.state)
    expect(proposal_payload["materialized_epic_state_path"]).to eq("/api/v1/app/epics/#{epic.id}/state")
  end

  it "creates a manual bookmark through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    message = chat.messages.create!(role: "assistant", content: { "text" => "Build aqueducts." })

    expect {
      post "/api/v1/app/chats/#{chat.id}/bookmarks", params: { message_id: message.id, chat_bookmark: { label: "Aqueducts" } }
    }.to change(ChatBookmark, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Bookmarked Aqueducts.")
    expect(parse_body["bookmarks"]).to contain_exactly(include("label" => "Aqueducts", "chat_message_id" => message.id, "anchor_message_id" => message.id))
  end

  it "creates a topic bookmark on the latest message through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    chat.messages.create!(role: "user", content: { "text" => "Earlier context." })
    latest = chat.messages.create!(role: "assistant", content: { "text" => "Plan aqueduct arches." })

    expect {
      post "/api/v1/app/chats/#{chat.id}/bookmarks", params: { chat_bookmark: { label: "Arch plan", kind: "topic" } }
    }.to change(ChatBookmark.topic, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Bookmarked Arch plan.")
    expect(parse_body["bookmarks"]).to contain_exactly(include("label" => "Arch plan", "chat_message_id" => latest.id, "anchor_message_id" => latest.id))
  end

  it "adds and removes attachments through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, last_message_at: Time.current)

    expect {
      post "/api/v1/app/chats/#{chat.id}/attachments", params: { attachable_type: "Repository", attachable_id: repository.id }
    }.to change(ChatAttachment, :count).by(1)

    expect(response).to have_http_status(:ok)
    attachment = chat.reload.chat_attachments.sole
    expect(attachment.attachable).to eq(repository)
    expect(parse_body["message"]).to eq("acme/widgets attached.")
    expect(parse_body.dig("attachment_groups", "repositories")).to contain_exactly(include(
      "label" => "acme/widgets",
      "app_detach_path" => "/api/v1/app/chats/#{chat.id}/attachments/#{attachment.id}"
    ))
    expect(parse_body.dig("attachment_groups", "repositories").first).not_to have_key("detach_path")

    expect {
      delete "/api/v1/app/chats/#{chat.id}/attachments/#{attachment.id}"
    }.to change(ChatAttachment, :count).by(-1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("acme/widgets detached.")
    expect(parse_body.dig("attachment_groups", "repositories")).to eq([])
  end

  it "renders attached Epics with their titles" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, last_message_at: Time.current)
    epic = Factories.epic(user: user, repository: repository, title: "Raise the forum")

    expect {
      post "/api/v1/app/chats/#{chat.id}/attachments", params: { attachable_type: "Epic", attachable_id: epic.id }
    }.to change(ChatAttachment, :count).by(1)

    expect(response).to have_http_status(:ok)
    attachment = chat.reload.chat_attachments.sole
    label = "#{epic.slug}: Raise the forum"
    expect(parse_body["message"]).to eq("#{label} attached.")
    expect(parse_body.dig("attachment_groups", "epics")).to contain_exactly(include(
      "label" => label,
      "app_detach_path" => "/api/v1/app/chats/#{chat.id}/attachments/#{attachment.id}"
    ))
  end

  it "attaches a repository by slug through the app API" do
    sign_in_as(user)
    repository
    chat = ChatSession.create!(user: user, last_message_at: Time.current)

    expect {
      post "/api/v1/app/chats/#{chat.id}/attachments", params: { attachable_type: "Repository", repository_slug: "acme/widgets" }
    }.to change(ChatAttachment, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(chat.reload.attached_repositories).to contain_exactly(repository)
    expect(parse_body["message"]).to eq("acme/widgets attached.")
  end

  it "renames a chat through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Old title", last_message_at: Time.current)

    patch "/api/v1/app/chats/#{chat.id}/rename", params: { chat: { title: "Canal review" } }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.title).to eq("Canal review")
    expect(parse_body["message"]).to eq("Chat renamed.")
    expect(parse_body.dig("chat", "title")).to eq("Canal review")
  end

  it "requests a kill for a running agent process when stopping a chat" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Active turn", last_message_at: Time.current)
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )

    post "/api/v1/app/chats/#{chat.id}/stop"

    expect(response).to have_http_status(:ok)
    expect(chat.reload.stop_requested_at).to be_present
    expect(process.reload.kill_requested_at).to be_present
    expect(process.kill_requested_by_user).to eq(user)
    expect(parse_body["message"]).to eq("Stop requested.")
    expect(parse_body.dig("chat", "stop_requested_at")).to be_present
  end

  it "reconciles a stop immediately when no chat agent process is live" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Already stopped", last_message_at: Time.current)
    chat.messages.create!(role: "user", content: { "text" => "Please stop" })

    post "/api/v1/app/chats/#{chat.id}/stop"

    expect(response).to have_http_status(:ok)
    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ]
    )
    expect(parse_body["message"]).to eq("Stop requested.")
    expect(parse_body.dig("chat", "stop_requested_at")).to be_nil
    expect(parse_body.dig("chat", "turn_in_flight")).to eq(false)
  end

  it "clears chat messages and queued messages through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Keep title", last_message_at: Time.current, stop_requested_at: Time.current)
    chat.messages.create!(role: "user", content: { "text" => "Start" })
    chat.chat_queued_messages.create!(content: { "text" => "Next" })

    expect {
      delete "/api/v1/app/chats/#{chat.id}/messages"
    }.to change(ChatMessage, :count).by(-1)
      .and change(ChatQueuedMessage, :count).by(-1)

    expect(response).to have_http_status(:ok)
    expect(chat.reload.title).to eq("Keep title")
    expect(chat.last_message_at).to be_nil
    expect(chat.stop_requested_at).to be_nil
    expect(parse_body["message"]).to eq("Chat history cleared.")
    expect(parse_body["messages"]).to eq([])
    expect(parse_body["queued_messages"]).to eq([])
  end

  it "does not attach another user's repository through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, last_message_at: Time.current)
    foreign = Factories.repository(user: Factories.user)

    expect {
      post "/api/v1/app/chats/#{chat.id}/attachments", params: { attachable_type: "Repository", attachable_id: foreign.id }
    }.not_to change(ChatAttachment, :count)

    expect(response).to have_http_status(:not_found)
  end

  it "does not attach archived repositories through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, last_message_at: Time.current)
    repository.archive!

    expect {
      post "/api/v1/app/chats/#{chat.id}/attachments", params: { attachable_type: "Repository", attachable_id: repository.id }
    }.not_to change(ChatAttachment, :count)

    expect(response).to have_http_status(:not_found)
  end

  it "confirms and rejects proposals through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    confirmed = chat.proposals.create!(slug: "auth-map", title: "Map auth", body: "Map it.")
    rejected = chat.proposals.create!(slug: "cleanup", title: "Clean up", body: "Sweep it.")
    chat.messages.create!(role: "assistant", proposal: confirmed, content: { "text" => "Proposal proposed." })
    chat.messages.create!(role: "assistant", proposal: rejected, content: { "text" => "Another proposal." })

    expect {
      post "/api/v1/app/chats/#{chat.id}/proposals/#{confirmed.id}/confirm"
    }.to change(Job, :count).by(1)
      .and change { chat.messages.reload.where(role: "system").count }.by(1)
      .and change { chat.messages.reload.where(role: "user").count }.by(0)
      .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to match(/\AProposal confirmed and filed as JOB-\d+\.\z/)
    expect(confirmed.reload).to be_confirmed
    expect(parse_body["messages"].first.dig("proposal", "materialized_label")).to eq("JOB-#{confirmed.job.id}")
    confirmation_message = chat.messages.where(role: "system").order(:created_at, :id).last
    expect(confirmation_message).to have_attributes(role: "system", proposal_id: nil)
    expect(confirmation_message.proposal_id).to be_nil
    expect(confirmation_message.content).to eq(
      "text" => %(Proposal confirmed. JOB-#{confirmed.job.id} "Map auth" was created.),
      "source" => "proposal_notification",
      "outcome" => "confirmed",
      "acknowledgment" => "Confirmed JOB-#{confirmed.job.id}."
    )
    expect(ChatTurnJob).to have_been_enqueued.with(chat.id, confirmation_message.id)

    expect {
      post "/api/v1/app/chats/#{chat.id}/proposals/#{rejected.id}/reject"
    }.to change { chat.messages.reload.where(role: "system").count }.by(1)
      .and change { chat.messages.reload.where(role: "user").count }.by(0)
      .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Proposal rejected.")
    expect(rejected.reload).to be_rejected
    rejection_message = chat.messages.where(role: "system").order(:created_at, :id).last
    expect(rejection_message).to have_attributes(role: "system", proposal_id: nil)
    expect(rejection_message.proposal_id).to be_nil
    expect(rejection_message.content).to eq(
      "text" => %(Proposal rejected. "Clean up" was discarded.),
      "source" => "proposal_notification",
      "outcome" => "rejected",
      "acknowledgment" => "Rejected proposal cleanup."
    )
    expect(ChatTurnJob).to have_been_enqueued.with(chat.id, rejection_message.id)
  end

  it "records confirmed Epic bundle details in a system chat message" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = chat.proposals.create!(
      slug: "ship-auth",
      title: "Ship auth",
      body: "Group the auth work.",
      kind: "epic",
      repository: repository
    )
    schema = proposal.child_proposals.create!(
      chat_session: chat,
      slug: "auth-schema",
      title: "Auth schema",
      body: "Add tables.",
      repository: repository
    )
    ui = proposal.child_proposals.create!(
      chat_session: chat,
      slug: "auth-ui",
      title: "Auth UI",
      body: "Add screens.",
      repository: repository
    )

    post "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}/confirm"

    expect(response).to have_http_status(:ok)
    expect(proposal.reload).to be_confirmed
    expect(schema.reload.job).to be_present
    expect(ui.reload.job).to be_present
    confirmation_message = chat.messages.where(role: "system").order(:created_at, :id).last
    expect(confirmation_message).to have_attributes(role: "system", proposal_id: nil)
    expect(confirmation_message.content.fetch("text")).to eq(
      "Proposal confirmed. Epic ##{proposal.epic.id} \"Ship auth\" was created. " \
      "Child jobs: JOB-#{schema.job.id} \"Auth schema\", JOB-#{ui.job.id} \"Auth UI\"."
    )
    expect(confirmation_message.content).to include(
      "source" => "proposal_notification",
      "outcome" => "confirmed",
      "acknowledgment" => "Confirmed #{proposal.epic.slug}."
    )
    expect(chat.messages.where(role: "user").count).to eq(0)
  end

  it "rejects proposed child proposals when rejecting an Epic proposal" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = chat.proposals.create!(
      slug: "ship-auth",
      title: "Ship auth",
      body: "Group the auth work.",
      kind: "epic",
      repository: repository
    )
    proposed_child = proposal.child_proposals.create!(
      chat_session: chat,
      slug: "auth-schema",
      title: "Auth schema",
      body: "Add tables.",
      repository: repository
    )
    confirmed_child = proposal.child_proposals.create!(
      chat_session: chat,
      slug: "auth-ui",
      title: "Auth UI",
      body: "Add screens.",
      repository: repository,
      state: "confirmed"
    )
    withdrawn_child = proposal.child_proposals.create!(
      chat_session: chat,
      slug: "auth-cleanup",
      title: "Auth cleanup",
      body: "Remove dead code.",
      repository: repository,
      state: "withdrawn"
    )

    post "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}/reject"

    expect(response).to have_http_status(:ok)
    expect(proposal.reload).to be_rejected
    expect(proposed_child.reload).to be_rejected
    expect(proposed_child.rejected_at).to be_present
    expect(confirmed_child.reload).to be_confirmed
    expect(confirmed_child.rejected_at).to be_nil
    expect(withdrawn_child.reload).to be_withdrawn
    expect(withdrawn_child.rejected_at).to be_nil
  end

  it "rejects product-owner confirmation of Job proposals targeting an Epic" do
    user.update!(role: "product_owner")
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    epic = Factories.epic(user: user, repository: repository, state: "backlog")
    proposal = chat.proposals.create!(
      slug: "auth-map",
      title: "Map auth",
      body: "Map it.",
      repository: repository,
      target_epic: epic
    )

    expect {
      post "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}/confirm"
    }.not_to change(Job, :count)

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "message")).to eq(
      "Product owners cannot add Jobs to Epics directly — claim the Epic as a developer to elaborate it."
    )
    expect(proposal.reload).to be_proposed
  end

  it "rejects product-owner confirmation of Epic bundles with child Jobs" do
    user.update!(role: "product_owner")
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = chat.proposals.create!(
      slug: "ship-auth",
      title: "Ship auth",
      body: "Group the auth work.",
      kind: "epic",
      repository: repository
    )
    proposal.child_proposals.create!(
      chat_session: chat,
      slug: "auth-schema",
      title: "Auth schema",
      body: "Add tables.",
      repository: repository
    )

    expect {
      post "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}/confirm"
    }.not_to change(Job, :count)

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "message")).to eq(
      "Product owners cannot add Jobs to Epics directly — claim the Epic as a developer to elaborate it."
    )
    expect(proposal.reload).to be_proposed
    expect(proposal.epic).to be_nil
  end

  it "enqueues proposal outcome control events while a chat turn is active" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    proposal = chat.proposals.create!(slug: "cleanup", title: "Clean up", body: "Sweep it.")
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )

    expect {
      post "/api/v1/app/chats/#{chat.id}/proposals/#{proposal.id}/reject"
    }.to change { chat.messages.reload.where(role: "system").count }.by(1)
      .and change { chat.messages.reload.where(role: "user").count }.by(0)
      .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

    expect(response).to have_http_status(:ok)
    control_event = chat.messages.where(role: "system").order(:created_at, :id).last
    expect(control_event.content).to include(
      "text" => %(Proposal rejected. "Clean up" was discarded.),
      "source" => "proposal_notification",
      "acknowledgment" => "Rejected proposal cleanup."
    )
    expect(ChatTurnJob).to have_been_enqueued.with(chat.id, control_event.id)
  end

  it "confirms and rejects pending actions through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    job_to_cancel = Factories.job(repository: repository)
    job_to_keep = Factories.job(repository: repository, issue_number: 43)
    confirm_action = chat.pending_actions.create!(action: "cancel_job", payload: { "job_id" => job_to_cancel.id })
    reject_action = chat.pending_actions.create!(action: "cancel_job", payload: { "job_id" => job_to_keep.id })

    get "/api/v1/app/chats/#{chat.id}"

    expect(parse_body["pending_actions"]).to contain_exactly(
      include("id" => confirm_action.id, "label" => "Cancel JOB-#{job_to_cancel.id}", "app_confirm_path" => "/api/v1/app/chats/#{chat.id}/pending_actions/#{confirm_action.id}/confirm"),
      include("id" => reject_action.id, "label" => "Cancel JOB-#{job_to_keep.id}", "app_cancel_path" => "/api/v1/app/chats/#{chat.id}/pending_actions/#{reject_action.id}")
    )

    post "/api/v1/app/chats/#{chat.id}/pending_actions/#{confirm_action.id}/confirm"

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Pending action confirmed.")
    expect(confirm_action.reload).to be_confirmed
    expect(job_to_cancel.reload).to be_closed

    delete "/api/v1/app/chats/#{chat.id}/pending_actions/#{reject_action.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Pending action rejected.")
    expect(reject_action.reload).to be_rejected
    expect(job_to_keep.reload).to be_open
  end

  it "confirms chat feedback pending actions through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    job = Factories.job_record(repository: repository, state: "implemented")
    action = chat.pending_actions.create!(
      action: "submit_chat_feedback",
      payload: { "job_id" => job.id, "feedback" => "Please tighten this implementation." }
    )
    message = chat.messages.create!(role: "assistant", content: { "text" => "Feedback queued." }, pending_action: action)

    get "/api/v1/app/chats/#{chat.id}"

    expect(parse_body["pending_actions"]).to contain_exactly(
      include("id" => action.id, "label" => "Submit feedback on JOB-#{job.id}", "detail" => "Please tighten this implementation.", "chat_message_id" => message.id)
    )

    expect {
      post "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/confirm"
    }.to have_enqueued_job(RunJob)

    workflow = action.reload.result

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Feedback submitted. Workflow ##{workflow.id} has been queued.")
    expect(action).to be_confirmed
    expect(workflow).to have_attributes(trigger_kind: "chat_feedback")
    expect(workflow.artifact("chat_feedback")).to eq("Please tighten this implementation.")
  end

  it "counts proposed chat proposals and pending actions in the chat header payload" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    chat.proposals.create!(slug: "map-auth", title: "Map auth", body: "Map it.")
    chat.proposals.create!(slug: "confirmed-auth", title: "Confirmed auth", body: "Done.", state: "confirmed")
    chat.pending_actions.create!(action: "cancel_job", payload: { "job_id" => Factories.job(repository: repository).id })
    chat.pending_actions.create!(action: "retry_job", state: "queued", payload: { "job_id" => Factories.job(repository: repository, issue_number: 44).id })

    get "/api/v1/app/chats/#{chat.id}"

    expect(parse_body.dig("chat", "pending_proposal_count")).to eq(2)
  end

  it "renders queued pending actions and lets the operator cancel them" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    job = Factories.job_record(repository: repository, state: "running")
    action = chat.pending_actions.create!(
      action: "submit_chat_feedback",
      state: "queued",
      payload: { "job_id" => job.id, "feedback" => "Please tighten this implementation." }
    )

    get "/api/v1/app/chats/#{chat.id}"

    expect(parse_body["pending_actions"]).to contain_exactly(
      include("id" => action.id, "state" => "queued", "label" => "Submit feedback on JOB-#{job.id}", "detail" => "Please tighten this implementation.")
    )

    delete "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Pending action cancelled.")
    expect(action.reload).to be_cancelled
  end

  it "renders schedule recurring pending action details through the app API" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)
    action = chat.pending_actions.create!(
      user: user,
      repository: repository,
      action_type: "schedule_recurring",
      payload: {
        "label" => "Nightly sweep",
        "cron_expression" => "15 2 * * *",
        "prompt" => "Review open issues and suggest cleanup."
      }
    )

    get "/api/v1/app/chats/#{chat.id}"

    expect(parse_body["pending_actions"]).to contain_exactly(
      include(
        "id" => action.id,
        "label" => "Nightly sweep",
        "detail" => "Nightly sweep — 15 2 * * *\n\nReview open issues and suggest cleanup."
      )
    )
  end

  it "appends a message through the app API and returns the refreshed payload" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: 1.day.ago)

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Now inspect proposals" } }
    }.to change { chat.messages.count }.by(1)
      .and have_enqueued_job(ChatTitleJob).with(chat.id, kind_of(Integer))
      .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

    expect(response).to have_http_status(:ok)
    expect(chat.reload.last_message_at).to be > 1.minute.ago
    expect(parse_body["message"]).to eq("Message sent.")
    expect(parse_body["turn_in_flight"]).to eq(true)
    expect(parse_body["agent_busy"]).to eq(false)
    expect(parse_body.dig("chat", "turn_in_flight")).to eq(true)
    expect(parse_body.dig("chat", "agent_busy")).to eq(false)
  end

  it "stores valid file attachments on a chat message" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: 1.day.ago)
    attachment = {
      name: "aqueduct.png",
      mime_type: "image/png",
      data: Base64.strict_encode64("image-bytes"),
      ignored: "drop me"
    }

    post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Inspect this image", attachments: [ attachment ] } }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.messages.last.content).to eq(
      "text" => "Inspect this image",
      "attachments" => [
        {
          "name" => "aqueduct.png",
          "mime_type" => "image/png",
          "data" => Base64.strict_encode64("image-bytes")
        }
      ]
    )
  end

  it "returns a validation error for disallowed chat message attachment MIME types" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: 1.day.ago)

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: {
        chat_message: {
          text: "Inspect this file",
          attachments: [ { name: "script.js", mime_type: "application/javascript", data: "alert(1)" } ]
        }
      }
    }.not_to change(ChatMessage, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Attachment MIME type is not allowed.")
  end

  it "returns a validation error for oversized chat message attachment data" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: 1.day.ago)
    stub_const("Api::V1::App::ChatsController::CHAT_ATTACHMENT_MAX_BASE64_BYTES", 4)

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: {
        chat_message: {
          text: "Inspect this image",
          attachments: [ { name: "large.png", mime_type: "image/png", data: "abcde" } ]
        }
      }
    }.not_to change(ChatMessage, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Attachment data must be 7 MB or smaller.")
  end

  it "keeps ordinary chat message content unchanged when attachments are omitted" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: 1.day.ago)

    post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Now inspect proposals" } }

    expect(response).to have_http_status(:ok)
    expect(chat.reload.messages.last.content).to eq("text" => "Now inspect proposals")
  end

  it "streams a chat turn as server-sent events for CLI clients" do
    user.update!(api_token: "cli-token")
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: 1.day.ago)
    allow(ChatTurnJob).to receive(:perform_later) do |chat_id, _message_id|
      ChatSession.find(chat_id).messages.create!(role: "assistant", content: { text: "Built **aqueducts**." })
    end

    post "/api/v1/app/chats/#{chat.id}/message",
         params: { content: "Now inspect proposals" },
         headers: {
           "Authorization" => "Bearer cli-token",
           "Accept" => "text/event-stream"
         }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/event-stream")
    expect(response.body).to include("event: text_chunk")
    expect(response.body).to include("Built **aqueducts**.")
    expect(response.body).to include("event: turn_complete")
    expect(chat.reload.messages.where(role: "user").last.content).to eq("text" => "Now inspect proposals")
  end

  it "uses the first user message for a delayed initial title" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: 1.day.ago)
    first = chat.messages.create!(role: "user", content: { "text" => "Build the calendar" }, created_at: 1.hour.ago)

    post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "Also add email alerts" } }

    expect(response).to have_http_status(:ok)
    expect(ChatTitleJob).to have_been_enqueued.with(chat.id, first.id)
  end

  it "returns a validation error for blank chat messages" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, repository: repository, last_message_at: Time.current)

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { text: "  " } }
    }.not_to change(ChatMessage, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Message cannot be blank.")
  end

  it "does not attach another user's repository" do
    sign_in_as(user)
    foreign = Factories.repository(user: Factories.user)

    expect {
      post "/api/v1/app/chats", params: { repository_id: foreign.id }
    }.not_to change(ChatSession, :count)

    expect(response).to have_http_status(:not_found)
  end

  describe "POST /api/v1/app/chats/:id/switch_provider" do
    let(:chat) { ChatSession.create!(user: user) }

    it "returns 401 when not signed in" do
      post "/api/v1/app/chats/#{chat.id}/switch_provider", params: { provider: "codex" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "enqueues SwitchChatProviderJob with the target provider" do
      sign_in_as(user)

      expect {
        post "/api/v1/app/chats/#{chat.id}/switch_provider", params: { provider: "codex" }
      }.to have_enqueued_job(SwitchChatProviderJob).with(chat.id, "codex")

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to eq("Switching to codex.")
    end

    it "returns 422 for an invalid provider" do
      sign_in_as(user)

      post "/api/v1/app/chats/#{chat.id}/switch_provider", params: { provider: "unknown" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "returns 422 when a turn is in-flight" do
      sign_in_as(user)
      chat.messages.create!(role: "user", content: { "text" => "hello" })

      expect {
        post "/api/v1/app/chats/#{chat.id}/switch_provider", params: { provider: "codex" }
      }.not_to have_enqueued_job(SwitchChatProviderJob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("turn_in_flight")
    end

    it "returns 404 when the chat belongs to another user" do
      sign_in_as(Factories.user)

      post "/api/v1/app/chats/#{chat.id}/switch_provider", params: { provider: "claude" }

      expect(response).to have_http_status(:not_found)
    end
  end

  def create_indexed_message(chat_session, text:, role: "assistant")
    message = chat_session.messages.create!(role: role, content: { "text" => text })
    ChatMessageSearchIndex.insert(message)
    message
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(
        content,
        user_id UNINDEXED,
        chat_session_id UNINDEXED,
        chat_message_id UNINDEXED,
        role UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE TABLE chat_search_metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    SQL
  end
end
