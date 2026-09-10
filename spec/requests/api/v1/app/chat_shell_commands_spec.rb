require "rails_helper"

RSpec.describe "API: /api/v1/app/chats/:chat_id/shell_commands", type: :request do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def parse_body
    JSON.parse(response.body)
  end

  def enable_coding_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: enabled)
  end

  def coding_chat(**attrs)
    ChatSession.create!(
      { user: user, repository: repository, mode: "coding", coding_checkout_branch: "syrus-chat-1" }.merge(attrs)
    )
  end

  def enable_local_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "local_mode") do |record|
      record.category = "Labs"
      record.name = "Local Mode"
    end
    feature.update!(enabled: enabled)
  end

  def local_chat(**attrs)
    ChatSession.create!({ user: user, repository: repository, mode: "local" }.merge(attrs))
  end

  def connect_local_daemon!(chat)
    session = LocalDaemonSession.create!(chat_session: chat, user: user)
    session.mark_connected!(repo: "acme/widgets", branch: "main")
    session
  end

  describe "POST /api/v1/app/chats/:chat_id/shell_commands" do
    it "401s when signed out" do
      chat = coding_chat
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "404s when the coding_mode feature flag is off" do
      sign_in_as(user)
      chat = coding_chat
      enable_coding_mode!(enabled: false)

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("feature_disabled")
    end

    it "422s when the chat is not in coding mode" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, repository: repository, coding_checkout_branch: "syrus-chat-1")
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s when the chat has no attached repository" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, mode: "coding", coding_checkout_branch: "syrus-chat-1")
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:not_found)
    end

    it "404s when no coding checkout exists yet" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, repository: repository, mode: "coding")
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:not_found)
    end

    it "422s when command is blank" do
      sign_in_as(user)
      chat = coding_chat
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "   " }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "403s for a chat owner who only has read access to the attached repository" do
      other_owner = Factories.user
      shared_repository = Factories.repository(user: other_owner)
      RepositoryMembership.create!(repository: shared_repository, user: user, role: "read")
      sign_in_as(user)
      chat = coding_chat(repository: shared_repository)
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:forbidden)
    end

    it "404s for a chat the signed-in user cannot access at all" do
      sign_in_as(Factories.user)
      chat = coding_chat
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:not_found)
    end

    it "creates a ChatShellCommand and enqueues the run" do
      sign_in_as(user)
      chat = coding_chat
      enable_coding_mode!

      expect {
        post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }
      }.to have_enqueued_job(ChatShellCommandJob)

      expect(response).to have_http_status(:created)
      body = parse_body
      expect(body["command"]).to eq("echo hi")
      expect(body["running"]).to eq(true)
      expect(body["outcome"]).to be_nil
      command = ChatShellCommand.find(body["id"])
      expect(command.chat_session_id).to eq(chat.id)
      expect(command.user_id).to eq(user.id)
    end

    it "rejects a second command while one is already running" do
      sign_in_as(user)
      chat = coding_chat
      enable_coding_mode!
      chat.chat_shell_commands.create!(user: user, command: "sleep 100", started_at: Time.current)

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:conflict)
      expect(parse_body.dig("error", "code")).to eq("conflict")
    end

    it "rejects a command while an agent turn owns the checkout" do
      sign_in_as(user)
      chat = coding_chat
      chat.update_columns(turn_in_flight: true)
      enable_coding_mode!

      post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

      expect(response).to have_http_status(:conflict)
      expect(parse_body.dig("error", "code")).to eq("turn_in_flight")
    end
  end

  describe "POST /api/v1/app/chats/:chat_id/shell_commands/:id/cancel" do
    it "requests a kill on the running spawned_process" do
      sign_in_as(user)
      chat = coding_chat
      enable_coding_mode!
      command = chat.chat_shell_commands.create!(user: user, command: "sleep 100", started_at: Time.current)
      spawned_process = SpawnedProcess.create!(
        kind: "chat_shell_command", command: "sleep 100", hostname: "worker-1", started_at: Time.current
      )
      command.update!(spawned_process: spawned_process)

      post "/api/v1/app/chats/#{chat.id}/shell_commands/#{command.id}/cancel"

      expect(response).to have_http_status(:ok)
      expect(spawned_process.reload.kill_requested_at).to be_present
      expect(spawned_process.kill_requested_by_user_id).to eq(user.id)
    end

    it "422s when the command has already finished" do
      sign_in_as(user)
      chat = coding_chat
      enable_coding_mode!
      command = chat.chat_shell_commands.create!(
        user: user, command: "echo hi", started_at: Time.current, finished_at: Time.current, outcome: "succeeded"
      )

      post "/api/v1/app/chats/#{chat.id}/shell_commands/#{command.id}/cancel"

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns a conflict when the command has not started running yet" do
      sign_in_as(user)
      chat = coding_chat
      enable_coding_mode!
      command = chat.chat_shell_commands.create!(user: user, command: "echo hi", started_at: Time.current)

      post "/api/v1/app/chats/#{chat.id}/shell_commands/#{command.id}/cancel"

      expect(response).to have_http_status(:conflict)
      expect(parse_body.dig("error", "code")).to eq("not_started")
    end

    it "403s for a chat owner who only has read access to the attached repository" do
      other_owner = Factories.user
      shared_repository = Factories.repository(user: other_owner)
      RepositoryMembership.create!(repository: shared_repository, user: user, role: "read")
      sign_in_as(user)
      chat = coding_chat(repository: shared_repository)
      enable_coding_mode!
      command = chat.chat_shell_commands.create!(user: user, command: "sleep 100", started_at: Time.current)

      post "/api/v1/app/chats/#{chat.id}/shell_commands/#{command.id}/cancel"

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "Local Mode" do
    describe "POST /api/v1/app/chats/:chat_id/shell_commands" do
      it "404s when the local_mode feature flag is off" do
        sign_in_as(user)
        chat = local_chat
        connect_local_daemon!(chat)
        enable_local_mode!(enabled: false)

        post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

        expect(response).to have_http_status(:not_found)
        expect(parse_body.dig("error", "code")).to eq("feature_disabled")
      end

      it "404s when no daemon is connected yet" do
        sign_in_as(user)
        chat = local_chat
        enable_local_mode!

        post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

        expect(response).to have_http_status(:not_found)
      end

      it "404s when a daemon session row exists but the daemon has never actually handshaken (JOB-609 visual review)" do
        sign_in_as(user)
        chat = local_chat
        enable_local_mode!
        # Mirrors LocalDaemonSessionsController#create: minting the session
        # row to hand the operator a connect token, before `syrus local` has
        # ever dialed in and completed the "connect" handshake.
        LocalDaemonSession.create!(chat_session: chat, user: user)

        post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

        expect(response).to have_http_status(:not_found)
        expect(ChatShellCommand.where(chat_session: chat)).to be_empty
      end

      it "creates a ChatShellCommand and enqueues the run once a daemon is connected" do
        sign_in_as(user)
        chat = local_chat
        connect_local_daemon!(chat)
        enable_local_mode!

        expect {
          post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "npm test" }
        }.to have_enqueued_job(ChatShellCommandJob)

        expect(response).to have_http_status(:created)
        command = ChatShellCommand.find(parse_body["id"])
        expect(command.chat_session_id).to eq(chat.id)
      end

      it "rejects a second command while one is already running" do
        sign_in_as(user)
        chat = local_chat
        connect_local_daemon!(chat)
        enable_local_mode!
        chat.chat_shell_commands.create!(user: user, command: "sleep 100", started_at: Time.current)

        post "/api/v1/app/chats/#{chat.id}/shell_commands", params: { command: "echo hi" }

        expect(response).to have_http_status(:conflict)
        expect(parse_body.dig("error", "code")).to eq("conflict")
      end
    end

    describe "POST /api/v1/app/chats/:chat_id/shell_commands/:id/cancel" do
      it "requests a cancel through the daemon tunnel" do
        sign_in_as(user)
        chat = local_chat
        session = connect_local_daemon!(chat)
        enable_local_mode!
        call = LocalToolCall.create!(local_daemon_session: session, chat_session: chat, tool_use_id: "call-1", tool_name: "run_command", state: "dispatched")
        command = chat.chat_shell_commands.create!(user: user, command: "sleep 100", started_at: Time.current, local_tool_call: call)

        broadcasts = []
        allow(ActionCable.server).to receive(:broadcast) { |stream, msg| broadcasts << [ stream, msg ] }

        post "/api/v1/app/chats/#{chat.id}/shell_commands/#{command.id}/cancel"

        expect(response).to have_http_status(:ok)
        expect(broadcasts).to include([ "local_daemon_session_#{session.id}_tool_calls", { type: "cancel", tool_call_id: call.id } ])
      end

      it "returns a conflict when the daemon hasn't started the command yet" do
        sign_in_as(user)
        chat = local_chat
        connect_local_daemon!(chat)
        enable_local_mode!
        command = chat.chat_shell_commands.create!(user: user, command: "echo hi", started_at: Time.current)

        post "/api/v1/app/chats/#{chat.id}/shell_commands/#{command.id}/cancel"

        expect(response).to have_http_status(:conflict)
        expect(parse_body.dig("error", "code")).to eq("not_started")
      end
    end
  end
end
