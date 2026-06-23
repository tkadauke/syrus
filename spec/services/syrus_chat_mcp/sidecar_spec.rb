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
        SyrusChatMcp::RenameChatTool,
        SyrusChatMcp::UpdatePinnedContextTool,
        SyrusChatMcp::RemovePinnedContextTool,
        SyrusChatMcp::AskUserQuestionTool,
        SyrusChatMcp::SetBookmarkTool,
        SyrusChatMcp::ProposeEpicWithJobsTool,
        SyrusChatMcp::ListChatsTool,
        SyrusChatMcp::ListProposalsTool,
        SyrusChatMcp::DeleteProposalTool,
        SyrusChatMcp::ListEpicsTool,
        SyrusChatMcp::ReadEpicTool,
        SyrusChatMcp::StartEpicTool,
        SyrusChatMcp::MoveEpicToBacklogTool,
        SyrusChatMcp::ArchiveEpicTool,
        SyrusChatMcp::UpdateEpicTool,
        SyrusChatMcp::ReadJobTool,
        SyrusChatMcp::UpdateJobTool,
        SyrusChatMcp::ListJobWorkflowsTool,
        SyrusChatMcp::ReadWorkflowTool,
        SyrusChatMcp::ReadRunTranscriptTool,
        SyrusChatMcp::SearchChatsTool,
        SyrusChatMcp::ReadChatMessagesTool,
        SyrusChatMcp::ListJobsTool,
        SyrusChatMcp::SearchJobsTool,
        SyrusChatMcp::ApproveJobTool,
        SyrusChatMcp::UnapproveJobTool,
        SyrusChatMcp::SetJobPriorityTool,
        SyrusChatMcp::AssignJobToEpicTool,
        SyrusChatMcp::RemoveJobFromEpicTool,
        SyrusChatMcp::CancelJobTool,
        SyrusChatMcp::RetryJobTool,
        SyrusChatMcp::RebaseJobTool,
        SyrusChatMcp::SubmitChatFeedbackTool,
        SyrusChatMcp::ReadPrTool,
        SyrusChatMcp::WriteMemoryTool,
        SyrusChatMcp::ReadMemoryTool,
        SyrusChatMcp::SearchMemoriesTool,
        SyrusChatMcp::ListMemoriesTool,
        SyrusChatMcp::DeleteMemoryTool,
        SyrusChatMcp::PublishMemoryTool,
        SyrusChatMcp::UnpublishMemoryTool,
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
        SyrusChatMcp::ScheduleRecurringTool,
        SyrusChatMcp::ListScheduledTasksTool,
        SyrusChatMcp::PauseScheduledTaskTool,
        SyrusChatMcp::ResumeScheduledTaskTool,
        SyrusChatMcp::DeleteScheduledTaskTool,
        SyrusChatMcp::ReadQueueTool
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
        list_scheduled_tasks
        pause_scheduled_task
        resume_scheduled_task
        delete_scheduled_task
        read_queue
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
