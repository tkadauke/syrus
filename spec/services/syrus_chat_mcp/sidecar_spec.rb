require "rails_helper"

RSpec.describe SyrusChatMcp::Sidecar do
  before do
    feature = Feature.find_or_create_by!(slug: "video_walkthroughs") do |record|
      record.category = "Labs"
      record.name = "Walkthrough videos"
    end
    feature.update!(enabled: true)
    Feature.find_or_create_by!(slug: "agent_insights") { |record| record.category = "Labs"; record.name = "Agent Insights" }
           .update!(enabled: false)
    Feature.clear_enabled_cache!("agent_insights")
  end

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
        close_job_successfully
        retry_job
        set_job_priority
        write_memory
        read_memory
        repo_info
        submit_chat_feedback
        rename_chat
        suggest_next_step
        ask_user_question
      ])
      expect(tool_names.size).to eq(24)
      expect(tool_names).not_to include("complete_implement_step")
    end

    it "exposes coding tools only in Coding Mode when the feature flag is on" do
      feature = Feature.find_or_create_by!(slug: "coding_mode") { |f| f.category = "Labs"; f.name = "Coding Mode" }
      feature.update!(enabled: true)
      coding_session = ChatSession.create!(user: user, repository: repository, mode: "coding")

      coding_tool_names = described_class.tool_names(coding_session, tier: :essential)
      planning_tool_names = described_class.tool_names(chat_session, tier: :essential)

      expect(coding_tool_names).to include("reset_workspace", "complete_implement_step", "submit_coding_changes")
      expect(planning_tool_names).not_to include("reset_workspace", "complete_implement_step", "submit_coding_changes")
    end

    it "hides coding tools in Coding Mode when the feature flag is off" do
      Feature.find_or_create_by!(slug: "coding_mode") { |f| f.category = "Labs"; f.name = "Coding Mode" }
              .update!(enabled: false)
      coding_session = ChatSession.create!(user: user, repository: repository, mode: "coding")

      tool_names = described_class.tool_names(coding_session, tier: :essential)

      expect(tool_names).not_to include("reset_workspace", "complete_implement_step", "submit_coding_changes")
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

    it "advertises insight read tools via the deferred tools/list when agent_insights is enabled" do
      Feature.find_or_create_by!(slug: "agent_insights") { |f| f.category = "Labs"; f.name = "Agent Insights" }
             .update!(enabled: true)
      Feature.clear_enabled_cache!("agent_insights")

      server = server_for(chat_session, tier: :deferred)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |tool| tool[:name] }

      expect(tool_names).to include("list_insights", "read_insight")
      expect(tool_names).not_to include("submit_insight")
    end

    it "does not advertise attachment or work-creation tools to supervisor chats" do
      admin = Factories.user(admin: true)
      supervisor_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin), system_kind: "supervisor")
      essential_server = server_for(supervisor_session, tier: :essential)
      deferred_server = server_for(supervisor_session, tier: :deferred)
      _ = jsonrpc(essential_server, "initialize", id: 0)
      _ = jsonrpc(deferred_server, "initialize", id: 0)

      essential_response = jsonrpc(essential_server, "tools/list", id: 1)
      deferred_response = jsonrpc(deferred_server, "tools/list", id: 2)
      tool_names = essential_response[:result][:tools].map { |tool| tool[:name] } +
        deferred_response[:result][:tools].map { |tool| tool[:name] }

      expect(tool_names).not_to include(
        "attach_repository",
        "propose_epic",
        "propose_job",
        "propose_epic_with_jobs",
        "list_proposals",
        "delete_proposal",
        "submit_chat_feedback",
        "delegate_issue",
        "list_chat_media",
        "schedule_recurring",
        "fire_scheduled_task_now"
      )
      expect(tool_names).to include(
        "admin_overview",
        "read_queue",
        "search_jobs",
        "read_job",
        "list_job_workflows",
        "read_workflow",
        "read_run_transcript"
      )
    end

    it "assigns every chat MCP tool file to exactly one tier" do
      # Gather tool file basenames from the sidecar-specific directories AND the
      # shared mcp/tools/ namespace (memory tools migrated there in this refactor).
      sidecar_tool_names = Dir[Rails.root.join("app/services/syrus_chat_mcp/*_tool.rb")]
        .map { |path| File.basename(path, ".rb").sub(/_tool\z/, "") }
      shared_tool_names = Dir[Rails.root.join("app/services/mcp/tools/*_tool.rb")]
        .map { |path| File.basename(path, ".rb").sub(/_tool\z/, "") }
      chat_exposed_syrus_mcp_tool_names = %w[list_insights read_insight]
      file_tool_names = (sidecar_tool_names + shared_tool_names + chat_exposed_syrus_mcp_tool_names).sort

      essential_names = described_class.tool_names(tier: :essential)
      deferred_names  = described_class.tool_names(tier: :deferred)

      expect(essential_names & deferred_names).to be_empty
      expect((essential_names + deferred_names).sort).to eq(file_tool_names)
    end

    it "exposes deferred tool names through the deferred sidecar" do
      names = SyrusChatMcp::DeferredSidecar.tool_names(chat_session)

      expect(names).to include("draw_shape", "read_workflow", "assign_job_to_epic")
      expect(names).not_to include("repo_info", "rename_chat", "ask_user_question", "admin_overview")
    end

    it "registers search_syrus_docs in DEFERRED_TOOLS" do
      expect(SyrusChatMcp::DeferredSidecar::DEFERRED_TOOLS).to include(SyrusChatMcp::SearchSyrusDocsTool)
      expect(SyrusChatMcp::DeferredSidecar.tool_names(chat_session)).to include("search_syrus_docs")
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
        "admin_refresh_installations",
        "force_fail_job"
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
        "admin_refresh_installations",
        "force_fail_job"
      )
      admin_tool_names = tool_names.select { |name| name.start_with?("admin_") || name == "force_fail_job" }
      expect(described_class.tool_names(tier: :essential)).to include(*admin_tool_names)
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

  describe "walkthrough labs flag" do
    it "advertises the walkthrough tools only while the feature is enabled" do
      names = SyrusChatMcp::DeferredSidecar.tool_names(chat_session)
      expect(names).to include("get_walkthrough_analysis", "analyze_walkthrough_segment", "read_walkthrough_frame")

      Feature.find_by!(slug: "video_walkthroughs").update!(enabled: false)

      names = SyrusChatMcp::DeferredSidecar.tool_names(chat_session)
      expect(names).not_to include("get_walkthrough_analysis", "analyze_walkthrough_segment", "read_walkthrough_frame")
      expect(described_class.tool_names(chat_session, tier: :deferred)).not_to include("get_walkthrough_analysis")
    end
  end

  describe "local mode labs flag" do
    let(:local_mode_tools) { %w[read_file write_file list_files run_command git_diff git_status] }

    def enable_local_mode
      feature = Feature.find_or_initialize_by(slug: "local_mode")
      feature.update!(category: "Labs", name: "Local Mode", enabled: true)
    end

    it "does not advertise local mode tools for non-local sessions even when feature is enabled" do
      enable_local_mode

      names = described_class.tool_names(chat_session, tier: :essential)

      expect(names).not_to include(*local_mode_tools)
    end

    it "advertises local mode tools when feature is enabled and session mode is local" do
      enable_local_mode
      local_session = ChatSession.create!(user: user, repository: repository, mode: "local")

      names = described_class.tool_names(local_session, tier: :essential)

      expect(names).to include(*local_mode_tools)
    end

    it "does not advertise local mode tools when feature is disabled even in local mode" do
      local_session = ChatSession.create!(user: user, repository: repository, mode: "local")

      names = described_class.tool_names(local_session, tier: :essential)

      expect(names).not_to include(*local_mode_tools)
    end

    it "includes local mode tools in the tool tier coverage check when session is nil" do
      all_essential = described_class.tool_names(nil, tier: :essential)

      expect(all_essential).to include(*local_mode_tools)
    end
  end
end
