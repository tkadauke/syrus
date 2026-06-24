require "rails_helper"

RSpec.describe SyrusChatMcp::Sidecar do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server_for(chat_session)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: described_class.tools_for(chat_session),
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def with_chat_session_env(value)
    original = ENV["SYRUS_CHAT_SESSION_ID"]
    value.nil? ? ENV.delete("SYRUS_CHAT_SESSION_ID") : ENV["SYRUS_CHAT_SESSION_ID"] = value
    yield
  ensure
    original.nil? ? ENV.delete("SYRUS_CHAT_SESSION_ID") : ENV["SYRUS_CHAT_SESSION_ID"] = original
  end

  def with_current_message_env(value)
    original = ENV["SYRUS_CHAT_CURRENT_MESSAGE_ID"]
    value.nil? ? ENV.delete("SYRUS_CHAT_CURRENT_MESSAGE_ID") : ENV["SYRUS_CHAT_CURRENT_MESSAGE_ID"] = value
    yield
  ensure
    original.nil? ? ENV.delete("SYRUS_CHAT_CURRENT_MESSAGE_ID") : ENV["SYRUS_CHAT_CURRENT_MESSAGE_ID"] = original
  end

  describe "MCP handshake" do
    it "responds to initialize with the chat sidecar server name" do
      response = jsonrpc(server_for(chat_session), "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "test", version: "1" } })

      expect(response[:result][:serverInfo]).to include(name: "syrus-chat-sidecar")
      expect(response[:result][:protocolVersion]).to be_a(String)
    end

    it "advertises the proposal tools via tools/list" do
      server = server_for(chat_session)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)

      tool_names = response[:result][:tools].map { |tool| tool[:name] }
      expect(tool_names).to eq(%w[
        attach_repository
        propose_issue
        propose_epic
        propose_job
        rename_chat
        update_pinned_context
        remove_pinned_context
        ask_user_question
        set_bookmark
        propose_epic_with_jobs
        list_chats
        list_proposals
        delete_proposal
        list_epics
        read_epic
        start_epic
        move_epic_to_backlog
        archive_epic
        update_epic
        add_epic_dependency
        remove_epic_dependency
        read_job
        update_job
        list_job_workflows
        read_workflow
        read_run_transcript
        search_chats
        read_chat_messages
        list_jobs
        search_jobs
        approve_job
        unapprove_job
        set_job_priority
        assign_job_to_epic
        remove_job_from_epic
        cancel_job
        retry_job
        rebase_job
        submit_chat_feedback
        read_pr
        write_memory
        read_memory
        search_memories
        list_memories
        delete_memory
        publish_memory
        unpublish_memory
        repo_info
        list_repo_documents
        read_repo_document
        read_scene
        draw_shape
        draw_text
        draw_line
        draw_arrow
        draw_freedraw
        draw_frame
        draw_embed
        draw_image
        move_element
        delete_element
        clear_canvas
        update_scene
        schedule_recurring
        schedule_wakeup
        list_scheduled_tasks
        pause_scheduled_task
        resume_scheduled_task
        delete_scheduled_task
        read_queue
      ])
    end

    it "does not advertise admin tools to non-admin users" do
      server = server_for(chat_session)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)

      tool_names = response[:result][:tools].map { |tool| tool[:name] }
      expect(tool_names).not_to include(
        "admin_overview",
        "admin_stuck_jobs",
        "admin_queue_detail",
        "admin_list_processes",
        "admin_list_runs",
        "admin_list_users",
        "admin_version",
        "admin_kill_process",
        "admin_reap_stale_runs",
        "admin_pause_polling",
        "admin_unpause_polling",
        "admin_pause_runs",
        "admin_unpause_runs",
        "admin_clear_github_cache",
        "admin_pause_user_scheduling",
        "admin_unpause_user_scheduling",
        "admin_retry_step",
        "admin_cleanup_workspace",
        "admin_refresh_installations"
      )
    end

    it "advertises admin tools to admin users" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin))
      server = server_for(admin_session)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)

      tool_names = response[:result][:tools].map { |tool| tool[:name] }
      expect(tool_names).to include(
        "admin_overview",
        "admin_stuck_jobs",
        "admin_queue_detail",
        "admin_list_processes",
        "admin_list_runs",
        "admin_list_users",
        "admin_version",
        "admin_kill_process",
        "admin_reap_stale_runs",
        "admin_pause_polling",
        "admin_unpause_polling",
        "admin_pause_runs",
        "admin_unpause_runs",
        "admin_clear_github_cache",
        "admin_pause_user_scheduling",
        "admin_unpause_user_scheduling",
        "admin_retry_step",
        "admin_cleanup_workspace",
        "admin_refresh_installations"
      )
    end
  end

  describe ".new" do
    it "loads the ChatSession from SYRUS_CHAT_SESSION_ID by default" do
      with_chat_session_env(chat_session.id.to_s) do
        sidecar = described_class.new
        expect(sidecar.instance_variable_get(:@chat_session)).to eq(chat_session)
      end
    end

    it "loads the ChatSession from an explicit session_id" do
      sidecar = described_class.new(session_id: chat_session.id)

      expect(sidecar.instance_variable_get(:@chat_session)).to eq(chat_session)
    end

    it "loads the current message from SYRUS_CHAT_CURRENT_MESSAGE_ID" do
      message = chat_session.messages.create!(role: "assistant", content: { "text" => "Confirm?" })

      with_current_message_env(message.id.to_s) do
        sidecar = described_class.new(session_id: chat_session.id)
        expect(sidecar.instance_variable_get(:@current_message)).to eq(message)
      end
    end

    it "raises KeyError when no session id is available" do
      with_chat_session_env(nil) do
        expect { described_class.new }.to raise_error(KeyError, /SYRUS_CHAT_SESSION_ID/)
      end
    end
  end
end
