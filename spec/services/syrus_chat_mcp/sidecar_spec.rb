require "rails_helper"

RSpec.describe SyrusChatMcp::Sidecar do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server_for(chat_session, tier: :all)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: described_class.tools_for(chat_session, tier: tier),
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(server, name, arguments = {})
    jsonrpc(server, "tools/call", params: { name: name, arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
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

  def with_sidecar_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  describe "MCP handshake" do
    it "responds to initialize with the chat sidecar server name" do
      response = jsonrpc(server_for(chat_session), "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "test", version: "1" } })

      expect(response[:result][:serverInfo]).to include(name: "syrus-chat-sidecar")
      expect(response[:result][:protocolVersion]).to be_a(String)
    end

    it "advertises only essential tools via the essential tools/list" do
      server = server_for(chat_session, tier: :essential)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)

      tool_names = response[:result][:tools].map { |tool| tool[:name] }
      expect(tool_names).to eq(%w[
        attach_repository
        propose_epic
        propose_job
        propose_epic_with_jobs
        list_proposals
        delete_proposal
        set_bookmark
        list_jobs
        search_jobs
        read_job
        list_epics
        read_epic
        approve_job
        cancel_job
        retry_job
        set_job_priority
        write_memory
        read_memory
        repo_info
        submit_chat_feedback
        rename_chat
        ask_user_question
      ])
      expect(tool_names.size).to eq(22)
    end

    it "advertises specialty tools via the deferred tools/list" do
      server = server_for(chat_session, tier: :deferred)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)

      tool_names = response[:result][:tools].map { |tool| tool[:name] }
      expect(tool_names).to include(*%w[
        read_scene
        update_pinned_context
        list_chats
        list_memories
        delete_memory
        publish_memory
        search_chats
        read_chat_messages
        add_epic_dependency
        remove_epic_dependency
        add_job_dependency
        remove_job_dependency
        get_spending
        get_job_diff
        list_tags
        create_tag
        add_job_tag
        remove_job_tag
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
        save_canvas
        clear_canvas
        load_canvas
        update_scene
        schedule_recurring
        schedule_wakeup
        list_wakeups
        cancel_wakeup
        list_scheduled_tasks
        pause_scheduled_task
        resume_scheduled_task
        delete_scheduled_task
        fire_scheduled_task_now
        pause_landing_queue
        resume_landing_queue
        read_queue
        list_repositories
        list_open_issues
        list_open_prs
        unapprove_job
        assign_job_to_epic
        remove_job_from_epic
      ])
      expect(tool_names).to include(
        "read_workflow",
        "read_run_transcript",
        "list_job_workflows",
        "read_queue",
        "read_pr",
        "rebase_job",
        "schedule_recurring",
        "list_scheduled_tasks",
        "pause_scheduled_task",
        "resume_scheduled_task",
        "delete_scheduled_task",
        "list_repo_documents",
        "read_repo_document"
      )
      expect(tool_names).not_to include("repo_info", "propose_job", "read_job", "write_memory", "read_memory", "rename_chat", "ask_user_question")
    end

    it "assigns every chat MCP tool file to exactly one tier" do
      file_tool_names = Dir[Rails.root.join("app/services/syrus_chat_mcp/*_tool.rb")]
        .map { |path| File.basename(path, ".rb").sub(/_tool\z/, "") }
        .sort
      essential_names = described_class.tool_names(tier: :essential)
      deferred_names = described_class.tool_names(tier: :deferred)

      expect(essential_names & deferred_names).to be_empty
      expect((essential_names + deferred_names).sort).to eq(file_tool_names)
    end

    it "exposes deferred tool names through the deferred sidecar" do
      names = SyrusChatMcp::DeferredSidecar.tool_names(chat_session)

      expect(names).to include("draw_shape", "read_workflow", "assign_job_to_epic")
      expect(names).not_to include("repo_info", "rename_chat", "ask_user_question", "admin_overview")
    end

    it "keeps deferred tool schemas callable through the deferred server" do
      server = server_for(chat_session, tier: :deferred)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)

      draw_shape = response[:result][:tools].find { |tool| tool[:name] == "draw_shape" }
      expect(draw_shape[:inputSchema]).to include(type: "object")
      expect(draw_shape[:description]).to be_present
    end

    it "keeps one deferred tool from each new MCP epic callable after deferred resolution" do
      admin = Factories.user(admin: true)
      admin_repository = Factories.repository(user: admin)
      admin_session = ChatSession.create!(user: admin, repository: admin_repository, title: "Admin chat")
      server = server_for(admin_session, tier: :deferred)
      _ = jsonrpc(server, "initialize", id: 0)
      prerequisite = Factories.epic(user: admin, repository: admin_repository)
      dependent = Factories.epic(user: admin, repository: admin_repository)

      calls = {
        "list_chats" => {},
        "list_memories" => {},
        "read_chat_messages" => { chat_session_id: admin_session.id },
        "add_epic_dependency" => { epic_id: dependent.id, depends_on_epic_id: prerequisite.id },
        "get_spending" => {}
      }

      calls.each do |tool_name, arguments|
        response = call_tool(server, tool_name, arguments)

        expect(response.dig(:result, :isError)).to be_falsey
      end

      expect(response_payload(call_tool(server, "list_chats"))[:chats].pluck(:id)).to include(admin_session.id)
      expect(dependent.reload.depends_on_epics).to contain_exactly(prerequisite)
    end

    it "does not advertise admin tools to non-admin users" do
      server = server_for(chat_session, tier: :deferred)
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

    it "exposes every chat tool advertised in the agent environment snapshot" do
      essential_server = server_for(chat_session)
      deferred_server = server_for(chat_session, tier: :deferred)
      _ = jsonrpc(essential_server, "initialize", id: 0)
      _ = jsonrpc(deferred_server, "initialize", id: 0)

      essential_response = jsonrpc(essential_server, "tools/list", id: 1)
      deferred_response = jsonrpc(deferred_server, "tools/list", id: 2)

      tool_names = essential_response[:result][:tools].map { |tool| tool[:name] } +
        deferred_response[:result][:tools].map { |tool| tool[:name] }
      advertised_tool_names = AgentEnvironmentSnapshot::CHAT_TOOL_GROUPS.values.flatten
      expect(tool_names).to include(*advertised_tool_names)
    end

    it "advertises admin tools to admin users" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin))
      server = server_for(admin_session, tier: :essential)
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
      expect(described_class.tool_names(tier: :essential)).to include(*tool_names.grep(/\Aadmin_/))
      expect(described_class.tool_names(tier: :deferred)).not_to include(*tool_names.grep(/\Aadmin_/))
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

    it "loads server name from env" do
      with_sidecar_env(
        "SYRUS_CHAT_MCP_TOOL_TIER" => "deferred",
        "SYRUS_CHAT_MCP_SERVER_NAME" => "syrus-chat-deferred-sidecar"
      ) do
        sidecar = described_class.new(session_id: chat_session.id)

        expect(sidecar.instance_variable_get(:@server_name)).to eq("syrus-chat-deferred-sidecar")
      end
    end

    it "raises KeyError when no session id is available" do
      with_chat_session_env(nil) do
        expect { described_class.new }.to raise_error(KeyError, /SYRUS_CHAT_SESSION_ID/)
      end
    end
  end
end
