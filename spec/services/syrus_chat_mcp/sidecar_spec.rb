require "rails_helper"

RSpec.describe SyrusChatMcp::Sidecar do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server_for(chat_session)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::AttachRepositoryTool,
        SyrusChatMcp::ProposeIssueTool,
        SyrusChatMcp::ProposeEpicTool,
        SyrusChatMcp::ProposeJobTool,
        SyrusChatMcp::SetBookmarkTool,
        SyrusChatMcp::ProposeEpicWithJobsTool,
        SyrusChatMcp::ListProposalsTool,
        SyrusChatMcp::DeleteProposalTool,
        SyrusChatMcp::ReadEpicTool,
        SyrusChatMcp::ReadJobTool,
        SyrusChatMcp::ListJobWorkflowsTool,
        SyrusChatMcp::ReadWorkflowTool,
        SyrusChatMcp::ReadRunTranscriptTool,
        SyrusChatMcp::ListJobsTool,
        SyrusChatMcp::CancelJobTool,
        SyrusChatMcp::RetryJobTool,
        SyrusChatMcp::RebaseJobTool,
        SyrusChatMcp::ReadPrTool,
        SyrusChatMcp::RepoInfoTool,
        SyrusChatMcp::ListRepoDocumentsTool,
        SyrusChatMcp::ReadRepoDocumentTool,
        SyrusChatMcp::ReadSceneTool,
        SyrusChatMcp::DrawShapeTool,
        SyrusChatMcp::DrawTextTool,
        SyrusChatMcp::DrawLineTool,
        SyrusChatMcp::DrawArrowTool,
        SyrusChatMcp::DrawFreedrawTool,
        SyrusChatMcp::DrawFrameTool,
        SyrusChatMcp::DrawEmbedTool,
        SyrusChatMcp::DrawImageTool,
        SyrusChatMcp::MoveElementTool,
        SyrusChatMcp::DeleteElementTool,
        SyrusChatMcp::ClearCanvasTool,
        SyrusChatMcp::UpdateSceneTool,
        SyrusChatMcp::ScheduleRecurringTool
      ],
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
        set_bookmark
        propose_epic_with_jobs
        list_proposals
        delete_proposal
        read_epic
        read_job
        list_job_workflows
        read_workflow
        read_run_transcript
        list_jobs
        cancel_job
        retry_job
        rebase_job
        read_pr
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
      ])
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

    it "raises KeyError when no session id is available" do
      with_chat_session_env(nil) do
        expect { described_class.new }.to raise_error(KeyError, /SYRUS_CHAT_SESSION_ID/)
      end
    end
  end
end
