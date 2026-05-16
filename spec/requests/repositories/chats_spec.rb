require "rails_helper"

RSpec.describe "Repository chats", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /repositories/:repository_id/chats" do
    it "renders an empty new-chat view without persisting a ChatSession" do
      expect {
        get repository_chats_path(repo)
      }.not_to change(ChatSession, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(repo.slug)
      expect(response.body).to include("Start a chat with this repository.")
      expect(response.body).to include("Tokens:")
      expect(response.body).to include('data-controller="chat-layout chat chat-side-panel"')
      expect(response.body).to include("data-chat-layout-storage-key-value=\"syrus.user.#{user.id}.repository.#{repo.id}.chat_split\"")
      expect(response.body).to include('data-chat-layout-whiteboard-enabled-value="false"')
      expect(response.body).to include("data-chat-side-panel-repository-id-value=\"#{repo.id}\"")
      expect(response.body).to include("data-chat-side-panel-documentation-url-value=\"/repositories/#{repo.id}/documents?frame=1\"")
      expect(response.body).to include('data-chat-layout-target="divider"')
      expect(response.body).to include("Hide canvas")
      expect(response.body).to include("Whiteboard")
      expect(response.body).to include("Documentation")
      expect(response.body).to include('data-chat-side-panel-target="documentationFrame"')
      expect(response.body).not_to include("<turbo-frame id=\"repository_#{repo.id}_documents\" src=")
      expect(response.body).not_to include('data-controller="whiteboard"')
      expect(response.body).not_to include(repository_whiteboard_path(repo))
    end

    it "still renders the chat for users whose default provider is Codex but who have a Claude token" do
      # Chat is Claude-only at the implementation level, but the
      # user's *default* provider for Jobs is independent — having
      # codex as the default doesn't disable chat as long as a
      # Claude OAuth token is configured.
      user.update!(
        agent_provider: "codex",
        codex_auth_mode: "api_key",
        codex_api_key: "sk-test"
      )

      get repository_chats_path(repo)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Start a chat with this repository.")
      expect(response.body).to include("New chat")
      expect(response.body).to include('name="chat_message[text]"')
      expect(response.body).not_to include("Chat requires Claude.")
    end

    it "renders the Claude credential onboarding notice when the token is missing" do
      user.update!(claude_oauth_token: nil)

      get repository_chats_path(repo)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Claude credentials are required.")
      expect(response.body).to include(edit_credentials_path)
      expect(response.body).not_to include("Start a chat with this repository.")
      expect(response.body).not_to include("New chat")
      expect(response.body).not_to include("name=\"chat_message[text]\"")
    end

    it "renders the newest chat by last_message_at" do
      older = ChatSession.create!(repository: repo, user: user, last_message_at: 2.hours.ago)
      older.messages.create!(role: "assistant", content: { "text" => "Old answer" })
      newer = ChatSession.create!(
        repository: repo,
        user: user,
        cumulative_input_tokens: 12_400,
        cumulative_output_tokens: 3_200,
        cumulative_cost_usd: 0.012345,
        last_message_at: 1.hour.ago
      )
      newer.messages.create!(role: "assistant", content: { "text" => "Newest answer" })

      get repository_chats_path(repo)

      expect(response.body).to include("Newest answer")
      expect(response.body).not_to include("Old answer")
      expect(response.body).to include("12.4k in")
      expect(response.body).to include("3.2k out")
      expect(response.body).to include("$0.0123")
      expect(response.body).to include("chat_session_#{newer.id}_messages")
      expect(response.body).to include("data-chat-layout-canvas-storage-key-value=\"syrus.chat.canvas.#{newer.id}\"")
      expect(response.body).to include(repository_chat_whiteboard_path(repo, newer))
      expect(response.body).to include("Refresh repo")
      expect(response.body).to include("Reset workspace")
    end

    it "renders attached Epic reference graph chips collapsed" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7, issue_title: "Sweep marble")
      chat.chat_attachments.create!(attachable: epic)

      get repository_chats_path(repo)

      expect(response.body).to include(epic.display_number)
      expect(response.body).to include("Dependency graph")
      expect(response.body).to include("data-controller=\"mermaid-graph\"")
      expect(response.body).to match(/<details(?![^>]*open)[^>]*>.*Dependency graph/m)
    end

    it "renders the chat whiteboard inside the layout side panel without eager-loading Excalidraw" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "box-1", "type" => "rectangle" } ] },
        version: 2
      )

      get repository_chats_path(repo)

      expect(response.body).to include('data-chat-layout-target="canvasPane"')
      expect(response.body).to include('aria-label="Chat side panel"')
      expect(response.body).to include('data-chat-side-panel-target="whiteboardPanel"')
      expect(response.body).to include('data-whiteboard-url-value="' + repository_chat_whiteboard_path(repo, chat) + '"')
      expect(response.body).not_to include('data-controller="whiteboard"')
      expect(response.body).to include("chat_session_#{chat.id}_whiteboard_broadcast")
      expect(response.body).to include('data-version="2"')
    end

    it "disables compose while the latest user message has no response" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      chat.messages.create!(role: "user", content: { "text" => "Ping" })

      get repository_chats_path(repo)

      expect(response.body).to include('data-chat-turn-in-flight-value="true"')
      expect(response.body).to include("disabled")
      expect(response.body).to include("Stop")
    end

    describe "tool-call grouping on initial render" do
      it "collapses consecutive same-name tool_use messages into one row with the details joined" do
        chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
        chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "a.py" } })
        chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "first" } ] })
        chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "b.py" } })
        chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "second" } ] })

        get repository_chats_path(repo)

        document = Nokogiri::HTML(response.body)
        groups = document.css('details[data-tool-call="true"]')
        expect(groups.size).to eq(1)
        summary = groups.first.at_css("summary").text
        expect(summary).to include("Read")
        expect(summary).to include("a.py, b.py")
      end

      it "hides standalone tool_result rows in the default view" do
        chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
        chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "a.py" } })
        chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "contents" } ] })

        get repository_chats_path(repo)

        document = Nokogiri::HTML(response.body)
        # No live-result wrapper (those are the JS-paired hidden ones)
        expect(document.css('[data-tool-call-result]').size).to eq(0)
        # No standalone tool_result_card box either.
        expect(response.body).not_to include('bg-emerald-50')
        # Result text is still in the DOM, inside the expand body.
        body = document.at_css('details[data-tool-call="true"] [data-tool-call-body]')
        expect(body.text).to include("contents")
      end
    end

    describe "message pagination on initial load" do
      it "renders only the latest 30 messages and reports more older are available" do
        chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
        40.times { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

        get repository_chats_path(repo)

        # Only the latest 30 chat-message wrappers are rendered.
        message_ids = response.body.scan(/id="chat_message_(\d+)"/).flatten.map(&:to_i)
        all_ids = chat.messages.order(:id).pluck(:id)
        expect(message_ids).to eq(all_ids.last(30))
        expect(response.body).to include('data-chat-has-more-older-value="true"')
      end

      it "reports no older messages when the session is short" do
        chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
        chat.messages.create!(role: "user", content: { "text" => "hi" })

        get repository_chats_path(repo)

        expect(response.body).to include('data-chat-has-more-older-value="false"')
      end
    end

    describe "GET /repositories/:repository_id/chats/:id/messages" do
      it "returns the page of older messages before the given id without a continuation when fewer than a page remain" do
        chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
        msgs = 40.times.map { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

        # Messages strictly older than msgs[29] are msgs[0..28] = 29 — fewer
        # than PAGE_SIZE — so the full set is returned and has_more is false.
        get repository_chat_messages_path(repo, chat), params: { before: msgs[29].id }

        expect(response).to have_http_status(:ok)
        returned_ids = response.body.scan(/id="chat_message_(\d+)"/).flatten.map(&:to_i)
        expect(returned_ids).to eq(msgs.first(29).map(&:id))
        expect(response.headers["X-Chat-Has-More-Older"]).to eq("false")
      end

      it "reports has-more=true when a full page of older messages was returned" do
        chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
        msgs = 70.times.map { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

        get repository_chat_messages_path(repo, chat), params: { before: msgs[40].id }

        expect(response.headers["X-Chat-Has-More-Older"]).to eq("true")
      end

      it "is not found on another user's chat" do
        other = Factories.user(claude_oauth_token: "oat-other")
        other_repo = Factories.repository(user: other, owner: "globex", name: "things")
        other_chat = ChatSession.create!(repository: other_repo, user: other, last_message_at: Time.current)

        get repository_chat_messages_path(other_repo, other_chat), params: { before: 999_999 }

        expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
      end
    end

    it "renders tool rows with proposal links" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      proposal = ChatProposal.create!(
        chat_session: chat,
        slug: "auth-map",
        title: "Map auth flow",
        body: "Trace the auth flow."
      )
      chat.messages.create!(
        role: "tool_result",
        tool_name: "propose_issue",
        proposal: proposal,
        content: { "slug" => "auth-map", "state" => "pending" }
      )

      get repository_chats_path(repo)

      expect(response.body).to include("propose_issue")
      expect(response.body).to include("Proposal ##{proposal.id} created (pending)")
      expect(response.body).to include(repository_proposals_path(repo))
    end

    it "renders pending confirmation cards" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      action = chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )

      get repository_chats_path(repo)

      expect(response.body).to include("Pending actions")
      expect(response.body).to include("Cancel Job")
      expect(response.body).to include("Job ##{job.id}")
      expect(response.body).to include(repository_chat_pending_action_confirm_path(repo, action))
      expect(response.body).to include(repository_chat_pending_action_path(repo, action))
    end
  end

  describe "pending action confirmation" do
    it "confirms a pending job-control action" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      action = chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )

      post repository_chat_pending_action_confirm_path(repo, action)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Pending action confirmed.")
      expect(action.reload).to be_confirmed
      expect(job.reload).to be_closed
    end

    it "rejects a pending action without applying it" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      action = chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )

      delete repository_chat_pending_action_path(repo, action)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Pending action rejected.")
      expect(action.reload).to be_rejected
      expect(job.reload).to be_open
    end

    it "does not apply an already-rejected stale action" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      action = chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )
      action.reject!

      post repository_chat_pending_action_confirm_path(repo, action)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:alert]).to eq("Pending action is no longer active.")
      expect(job.reload).to be_open
    end
  end

  describe "POST /repositories/:repository_id/chats" do
    it "shows an ephemeral new chat for an empty New chat post" do
      expect {
        post repository_chats_path(repo)
      }.not_to change(ChatSession, :count)

      expect(response).to redirect_to(repository_chats_path(repo, new_chat: "1"))
    end

    it "creates the chat, first user message, and enqueues a turn" do
      expect {
        post repository_chats_path(repo), params: { chat_message: { text: "Map the auth flow" } }
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob)

      chat = repo.chat_sessions.last
      message = chat.messages.last
      expect(chat.user).to eq(user)
      expect(chat.last_message_at).to be_present
      expect(message.role).to eq("user")
      expect(message.content).to eq("text" => "Map the auth flow")
      expect(response).to redirect_to(repository_chats_path(repo))
    end

  end

  describe "POST /repositories/:repository_id/chats/:id/message" do
    it "appends a user message to an existing chat and enqueues a turn" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: 1.day.ago)

      expect {
        post repository_chat_message_path(repo, chat), params: { chat_message: { text: "Now inspect proposals" } }
      }.to change { chat.messages.count }.by(1)
        .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

      expect(chat.reload.last_message_at).to be > 1.minute.ago
      expect(chat.messages.last.content).to eq("text" => "Now inspect proposals")
      expect(response).to redirect_to(repository_chats_path(repo))
    end

    it "rejects blank messages" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      expect {
        post repository_chat_message_path(repo, chat), params: { chat_message: { text: "  " } }
      }.not_to change(ChatMessage, :count)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:alert]).to eq("Message cannot be blank.")
    end
  end

  describe "POST /repositories/:repository_id/chats/:id/stop" do
    it "sets the stop flag on the chat session" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      post repository_chat_stop_path(repo, chat)

      expect(chat.reload.stop_requested_at).to be_present
      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Stop requested.")
    end
  end

  describe "POST /repositories/:repository_id/chats/:id/refresh" do
    it "enqueues a refresh workspace job" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      expect {
        post repository_chat_refresh_path(repo, chat)
      }.to have_enqueued_job(ChatWorkspaceJob).with(repo.id, action: :refresh)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Repository refresh queued.")
    end
  end

  describe "POST /repositories/:repository_id/chats/:id/reset" do
    it "enqueues a reset workspace job" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      expect {
        post repository_chat_reset_path(repo, chat)
      }.to have_enqueued_job(ChatWorkspaceJob).with(repo.id, action: :reset)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Workspace reset queued.")
    end
  end
end
