require "rails_helper"

RSpec.describe "Chats", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /chats/new" do
    it "renders the new top-level chat form without creating a chat" do
      repo

      expect {
        get new_chat_path
      }.not_to change(ChatSession, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("New chat")
      expect(response.body).to include("Create chat")
      expect(response.body).to include(repo.slug)
    end
  end

  describe "POST /chats" do
    it "creates a fresh chat with an optional repository attachment" do
      expect {
        post chats_path, params: { repository_id: repo.id }
      }.to change(ChatSession, :count).by(1)

      chat = ChatSession.last
      expect(chat.user).to eq(user)
      expect(chat.attached_repositories).to contain_exactly(repo)
      expect(response).to redirect_to(chat_path(chat))
    end

    it "creates the first message and enqueues a turn when a repository is attached" do
      expect {
        post chats_path, params: { repository_id: repo.id, chat_message: { text: "Map auth" } }
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob)

      chat = ChatSession.last
      expect(chat.messages.last.content).to eq("text" => "Map auth")
      expect(response).to redirect_to(chat_path(chat))
    end
  end

  describe "GET /chats/:id" do
    it "renders the chat page with attachment sidebar and in-scope documents" do
      document = repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Launch notes",
        google_docs_url: "https://docs.google.com/document/d/launch/edit"
      )
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      message = chat.messages.create!(role: "assistant", content: { "text" => "Discuss aqueducts." })
      message.bookmarks.create!(label: "Aqueducts", kind: "topic")

      get chat_path(chat)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Bookmarks")
      expect(response.body).to include("Aqueducts")
      expect(response.body).to include("#message-#{message.id}")
      expect(response.body).to include("Attachments")
      expect(response.body).to include("Add attachment")
      expect(response.body).to include(repo.slug)
      expect(response.body).to include(document.title)
      expect(response.body).to include(chat_attachments_path(chat))
      expect(response.body).to include(chat_message_path(chat))
      expect(response.body).to include(chat_whiteboard_path(chat))
    end

    it "renders message anchors and manual bookmark controls" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      message = chat.messages.create!(role: "assistant", content: { "text" => "Discuss roads." })

      get chat_path(chat)

      expect(response.body).to include("id=\"message-#{message.id}\"")
      expect(response.body).to include("Bookmark this")
      expect(response.body).to include(chat_bookmarks_path(chat))
      expect(response.body).to include("name=\"message_id\"")
    end

    it "renders usage, workspace controls, and the chat side-panel shell" do
      chat = ChatSession.create!(
        user: user,
        repository: repo,
        cumulative_input_tokens: 12_400,
        cumulative_output_tokens: 3_200,
        cumulative_cost_usd: 0.012345,
        last_message_at: Time.current
      )
      chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "box-1", "type" => "rectangle" } ] },
        version: 2
      )

      get chat_path(chat)

      expect(response.body).to include("12.4k in")
      expect(response.body).to include("3.2k out")
      expect(response.body).to include("$0.0123")
      expect(response.body).to include("data-chat-layout-canvas-storage-key-value=\"syrus.chat.canvas.#{chat.id}\"")
      expect(response.body).to include(chat_whiteboard_path(chat))
      expect(response.body).to include("Refresh repo")
      expect(response.body).to include("Reset workspace")
      expect(response.body).to include('aria-label="Chat side panel"')
      expect(response.body).to include('data-chat-side-panel-target="whiteboardPanel"')
      expect(response.body).to include("chat_session_#{chat.id}_whiteboard_broadcast")
      expect(response.body).to include('data-version="2"')
      expect(response.body).to include("box-1")
    end

    it "still renders for users whose default provider is Codex when Claude credentials exist" do
      user.update!(
        agent_provider: "codex",
        codex_auth_mode: "api_key",
        codex_api_key: "sk-test"
      )
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      get chat_path(chat)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("New chat")
      expect(response.body).to include('name="chat_message[text]"')
      expect(response.body).not_to include("Claude credentials are required.")
    end

    it "renders the Claude credential onboarding notice when the token is missing" do
      user.update!(claude_oauth_token: nil)
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      get chat_path(chat)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Claude credentials are required.")
      expect(response.body).to include(edit_credentials_path)
      expect(response.body).not_to include("Start a chat with this repository.")
      expect(response.body).not_to include("name=\"chat_message[text]\"")
    end

    it "disables compose while the latest user message has no response" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      chat.messages.create!(role: "user", content: { "text" => "Ping" })

      get chat_path(chat)

      expect(response.body).to include('data-chat-turn-in-flight-value="true"')
      expect(response.body).to include("disabled")
      expect(response.body).to include("Stop")
    end

    it "collapses consecutive same-name tool calls into one grouped row" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "a.py" } })
      chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "first" } ] })
      chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "b.py" } })
      chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "second" } ] })

      get chat_path(chat)

      document = Nokogiri::HTML(response.body)
      groups = document.css('details[data-tool-call="true"]')
      expect(groups.size).to eq(1)
      summary = groups.first.at_css("summary").text
      expect(summary).to include("Read")
      expect(summary).to include("a.py, b.py")
    end

    it "hides standalone tool result rows in the default grouped view" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      chat.messages.create!(role: "tool_use", tool_name: "Read", content: { "input" => { "file_path" => "a.py" } })
      chat.messages.create!(role: "tool_result", tool_name: "Read", content: { "result" => [ { "type" => "text", "text" => "contents" } ] })

      get chat_path(chat)

      document = Nokogiri::HTML(response.body)
      expect(document.css("[data-tool-call-result]").size).to eq(0)
      expect(response.body).not_to include("bg-emerald-50")
      body = document.at_css('details[data-tool-call="true"] [data-tool-call-body]')
      expect(body.text).to include("contents")
    end

    it "renders proposals as inline assistant cards with actions" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      proposal = ChatProposal.create!(
        chat_session: chat,
        slug: "auth-map",
        title: "Map auth flow",
        body: "Trace the auth flow."
      )
      chat.messages.create!(
        role: "assistant",
        proposal: proposal,
        content: { "text" => "Proposal proposed." }
      )

      get chat_path(chat)

      expect(response.body).to include("Map auth flow")
      expect(response.body).to include("Trace the auth flow.")
      expect(response.body).to include("Proposed")
      expect(response.body).to include(chat_proposal_confirm_path(chat, proposal))
      expect(response.body).to include(chat_proposal_reject_path(chat, proposal))
    end

    it "renders manual proposal buttons and modal forms in the composer" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      get chat_path(chat)

      expect(response.body).to include("Propose Epic")
      expect(response.body).to include("Propose Job")
      expect(response.body).to include("chat_session_#{chat.id}_epic_proposal_dialog")
      expect(response.body).to include("chat_session_#{chat.id}_job_proposal_dialog")
      expect(response.body).to include(chat_proposals_path(chat))
    end

    it "does not render pending actions in a side panel" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )

      get chat_path(chat)

      expect(response.body).not_to include("Pending actions")
      expect(response.body).not_to include("Cancel Job")
    end

    it "renders only the latest page of messages and exposes the older-message endpoint" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      40.times { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

      get chat_path(chat)

      message_ids = response.body.scan(/id="chat_message_(\d+)"/).flatten.map(&:to_i)
      expect(message_ids).to eq(chat.messages.order(:id).last(30).pluck(:id))
      expect(response.body).to include('data-chat-has-more-older-value="true"')
      expect(response.body).to include(chat_messages_path(chat))
    end

    it "reports no older messages when the session is short" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      chat.messages.create!(role: "user", content: { "text" => "hi" })

      get chat_path(chat)

      expect(response.body).to include('data-chat-has-more-older-value="false"')
    end
  end

  describe "GET /chats/:chat_id/messages" do
    it "returns the page of older messages before the given id without a continuation" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      msgs = 40.times.map { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

      get chat_messages_path(chat), params: { before: msgs[29].id }

      expect(response).to have_http_status(:ok)
      returned_ids = response.body.scan(/id="chat_message_(\d+)"/).flatten.map(&:to_i)
      expect(returned_ids).to eq(msgs.first(29).map(&:id))
      expect(response.headers["X-Chat-Has-More-Older"]).to eq("false")
    end

    it "reports has-more=true when a full page of older messages was returned" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      msgs = 70.times.map { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

      get chat_messages_path(chat), params: { before: msgs[40].id }

      expect(response.headers["X-Chat-Has-More-Older"]).to eq("true")
    end

    it "is not found on another user's chat" do
      other = Factories.user(claude_oauth_token: "oat-other")
      other_repo = Factories.repository(user: other, owner: "globex", name: "things")
      other_chat = ChatSession.create!(user: other, repository: other_repo, last_message_at: Time.current)

      get chat_messages_path(other_chat), params: { before: 999_999 }

      expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
    end
  end

  describe "POST /chats/:id/message" do
    it "appends a user message to an existing top-level chat and enqueues a turn" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: 1.day.ago)

      expect {
        post chat_message_path(chat), params: { chat_message: { text: "Now inspect proposals" } }
      }.to change { chat.messages.count }.by(1)
        .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

      expect(chat.reload.last_message_at).to be > 1.minute.ago
      expect(response).to redirect_to(chat_path(chat))
    end

    it "rejects blank messages" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      expect {
        post chat_message_path(chat), params: { chat_message: { text: "  " } }
      }.not_to change(ChatMessage, :count)

      expect(response).to redirect_to(chat_path(chat))
      expect(flash[:alert]).to eq("Message cannot be blank.")
    end
  end

  describe "POST /chats/:id/proposals" do
    it "creates a proposed Job card without enqueueing a chat turn" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: 1.day.ago)
      root = chat.proposals.create!(slug: "root", title: "Root", body: "Do root.")

      expect {
        post chat_proposals_path(chat), params: {
          chat_proposal: {
            kind: "syrus_issue",
            slug: "manual-job",
            title: "Manual Job",
            body: "Do the job.",
            labels: "ui, polish",
            depends_on: "root"
          }
        }
      }.to change(ChatProposal, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob).exactly(0).times

      proposal = chat.proposals.find_by!(slug: "manual-job")
      expect(response).to redirect_to(chat_path(chat))
      expect(proposal).to have_attributes(kind: "syrus_issue", title: "Manual Job", labels: %(["ui","polish"]))
      expect(proposal.dependencies).to contain_exactly(root)
      expect(chat.messages.last).to have_attributes(role: "assistant", proposal: proposal)

      get chat_path(chat)

      expect(response.body).to include("Manual Job")
      expect(response.body).to include("Do the job.")
      expect(response.body).to include("Proposed")
      expect(response.body).to include(chat_proposal_confirm_path(chat, proposal))
      expect(response.body).to include(chat_proposal_reject_path(chat, proposal))
    end

    it "creates a proposed Epic card that confirms into an Epic" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      post chat_proposals_path(chat), params: {
        chat_proposal: {
          kind: "epic",
          slug: "manual-epic",
          title: "Manual Epic",
          body: "Coordinate the work."
        }
      }

      proposal = chat.proposals.find_by!(slug: "manual-epic")
      expect(proposal).to have_attributes(kind: "epic", state: "proposed")

      expect {
        post chat_proposal_confirm_path(chat, proposal)
      }.to change(Epic, :count).by(1)

      expect(response).to redirect_to(chat_path(chat))
      expect(proposal.reload).to be_confirmed
      expect(proposal.epic).to have_attributes(title: "Manual Epic", description: "Coordinate the work.")
    end
  end

  describe "POST /chats/:id/bookmarks" do
    it "creates a manual bookmark on a message in the chat" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      message = chat.messages.create!(role: "assistant", content: { "text" => "Mark this." })

      expect {
        post chat_bookmarks_path(chat), params: {
          message_id: message.id,
          chat_bookmark: { label: "Marked point" }
        }
      }.to change(ChatBookmark, :count).by(1)

      bookmark = message.bookmarks.sole
      expect(bookmark).to be_manual
      expect(bookmark.label).to eq("Marked point")
      expect(response).to redirect_to(chat_path(chat, anchor: "message-#{message.id}"))
    end

    it "does not bookmark a message from another chat" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      other_chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      message = other_chat.messages.create!(role: "assistant", content: { "text" => "Do not mark this." })

      expect {
        post chat_bookmarks_path(chat), params: {
          message_id: message.id,
          chat_bookmark: { label: "Wrong chat" }
        }
      }.not_to change(ChatBookmark, :count)

      expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
    end
  end

  describe "POST /chats/:id/stop" do
    it "sets the stop flag on the chat session" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      post chat_stop_path(chat)

      expect(chat.reload.stop_requested_at).to be_present
      expect(response).to redirect_to(chat_path(chat))
      expect(flash[:notice]).to eq("Stop requested.")
    end
  end

  describe "workspace actions" do
    it "enqueues a refresh workspace job" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      expect {
        post chat_refresh_path(chat)
      }.to have_enqueued_job(ChatWorkspaceJob).with(repo.id, action: :refresh)

      expect(response).to redirect_to(chat_path(chat))
      expect(flash[:notice]).to eq("Repository refresh queued.")
    end

    it "enqueues a reset workspace job" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      expect {
        post chat_reset_path(chat)
      }.to have_enqueued_job(ChatWorkspaceJob).with(repo.id, action: :reset)

      expect(response).to redirect_to(chat_path(chat))
      expect(flash[:notice]).to eq("Workspace reset queued.")
    end
  end

  describe "attachment management" do
    it "adds and removes attachments" do
      chat = ChatSession.create!(user: user)

      post chat_attachments_path(chat), params: { attachable_type: "Repository", attachable_id: repo.id }

      expect(response).to redirect_to(chat_path(chat))
      attachment = chat.reload.chat_attachments.sole
      expect(attachment.attachable).to eq(repo)

      delete chat_attachment_path(chat, attachment)

      expect(response).to redirect_to(chat_path(chat))
      expect(chat.reload.chat_attachments).to be_empty
    end

    it "adds a repository document attachment from the Document picker" do
      document = repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Design notes",
        google_docs_url: "https://docs.google.com/document/d/design/edit"
      )
      chat = ChatSession.create!(user: user)

      post chat_attachments_path(chat), params: { attachable_type: "Document", attachable_id: document.id }

      expect(response).to redirect_to(chat_path(chat))
      expect(chat.reload.attached_repository_documents).to contain_exactly(document)
    end
  end

  describe "pending action confirmation" do
    it "confirms a pending job-control action" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      action = chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )

      post chat_pending_action_confirm_path(chat, action)

      expect(response).to redirect_to(chat_path(chat))
      expect(flash[:notice]).to eq("Pending action confirmed.")
      expect(action.reload).to be_confirmed
      expect(job.reload).to be_closed
    end

    it "rejects a pending action without applying it" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      action = chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )

      delete chat_pending_action_path(chat, action)

      expect(response).to redirect_to(chat_path(chat))
      expect(flash[:notice]).to eq("Pending action rejected.")
      expect(action.reload).to be_rejected
      expect(job.reload).to be_open
    end

    it "does not apply an already-rejected stale action" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      job = Factories.job(repository: repo)
      action = chat.pending_actions.create!(
        action: "cancel_job",
        payload: { "job_id" => job.id }
      )
      action.reject!

      post chat_pending_action_confirm_path(chat, action)

      expect(response).to redirect_to(chat_path(chat))
      expect(flash[:alert]).to eq("Pending action is no longer active.")
      expect(job.reload).to be_open
    end
  end

  describe "proposal state actions" do
    it "confirms a proposed card and links it to the created job" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      proposal = chat.proposals.create!(slug: "auth-map", title: "Map auth", body: "Map it.")
      chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

      expect {
        post chat_proposal_confirm_path(chat, proposal)
      }.to change(Job, :count).by(1)

      expect(response).to redirect_to(chat_path(chat))
      expect(proposal.reload).to be_confirmed
      expect(proposal.job).to be_present

      get chat_path(chat)

      expect(response.body).to include("Confirmed proposal")
      expect(response.body).to include("Job ##{proposal.job.id}")
      expect(response.body).to include(job_path(proposal.job))
    end

    it "rejects a proposed card while keeping history visible" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      proposal = chat.proposals.create!(slug: "auth-map", title: "Map auth", body: "Map it.")
      chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

      post chat_proposal_reject_path(chat, proposal)

      expect(response).to redirect_to(chat_path(chat))
      expect(proposal.reload).to be_rejected

      get chat_path(chat)

      expect(response.body).to include("Map auth")
      expect(response.body).to include("Rejected")
      expect(response.body).not_to include(chat_proposal_confirm_path(chat, proposal))
    end
  end

  describe "legacy repository chat URL" do
    it "redirects to the top-level chat and keeps the repository attached" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: 1.hour.ago)

      get repository_chats_path(repo)

      expect(response).to redirect_to(chat_path(chat))
      expect(chat.reload.attached_repositories).to contain_exactly(repo)
    end

    it "creates an attached chat when the old repository chat URL has no session yet" do
      expect {
        get repository_chats_path(repo)
      }.to change(ChatSession, :count).by(1)

      chat = ChatSession.last
      expect(response).to redirect_to(chat_path(chat))
      expect(chat.attached_repositories).to contain_exactly(repo)
    end
  end
end
