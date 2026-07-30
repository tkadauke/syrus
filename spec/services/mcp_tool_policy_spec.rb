require "rails_helper"

RSpec.describe McpToolPolicy do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def context_for(chat_session)
    McpToolContext.from_chat_session(chat_session)
  end

  def chat_session(**attrs)
    ChatSession.create!({ user: user, repository: repository }.merge(attrs))
  end

  describe "workflow roles" do
    let(:run) { Factories.job.initial_run }

    it "returns submit_summary and submit_test_plan for implement roles, not submit_adversarial_review" do
      context = McpToolContext.from_run(run)
      tools   = described_class.for(context)

      expect(tools).to include(
        SyrusMcp::ReadLiveStateTool,
        Mcp::Tools::ReadMemoryTool,
        Mcp::Tools::WriteMemoryTool,
        Mcp::Tools::DeleteMemoryTool,
        Mcp::Tools::SearchMemoriesTool,
        Mcp::Tools::ListMemoriesTool,
        SyrusMcp::GetCoverageReportTool,
        SyrusMcp::ReadRunWorkerHealthTool,
        SyrusMcp::StartPreviewTool,
        SyrusMcp::StopPreviewTool,
        SyrusMcp::ReadPreviewLogTool,
        SyrusMcp::SubmitSummaryTool,
        SyrusMcp::SubmitTestPlanTool,
        SyrusMcp::ReportMainConcernTool
      )
      expect(tools).not_to include(SyrusMcp::SubmitAdversarialReviewTool, SyrusMcp::SubmitJobMetadataTool)
      expect(tools.size).to eq(14)
    end

    it "returns submit_adversarial_review but not submit_summary for the adversarial_reviewer role" do
      context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
      tools   = described_class.for(context)

      expect(tools).to include(
        SyrusMcp::ReadLiveStateTool,
        SyrusMcp::ReadRunWorkerHealthTool,
        SyrusMcp::SubmitAdversarialReviewTool
      )
      expect(tools).not_to include(SyrusMcp::SubmitSummaryTool, SyrusMcp::SubmitTestPlanTool)
      expect(tools.size).to eq(12)
    end

    it "excludes report_main_concern from the adversarial_reviewer role" do
      context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
      tools   = described_class.for(context)

      expect(tools).not_to include(SyrusMcp::ReportMainConcernTool)
    end

    it "includes report_main_concern for the implement role" do
      context = McpToolContext.from_run(run)
      tools   = described_class.for(context)

      expect(tools).to include(SyrusMcp::ReportMainConcernTool)
    end

    it "includes performance diagnostics for tkadauke/syrus implementation runs" do
      syrus_repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")
      syrus_run = Factories.job(repository: syrus_repository, user: user).initial_run
      context = McpToolContext.from_run(syrus_run)

      expect(described_class.for(context)).to include(SyrusMcp::ReadPerformanceDiagnosticsTool)
    end

    it "includes Syrus log search for tkadauke/syrus implementation runs" do
      syrus_repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")
      syrus_run = Factories.job(repository: syrus_repository, user: user).initial_run
      context = McpToolContext.from_run(syrus_run)

      expect(described_class.for(context)).to include(SyrusMcp::ReadSyrusLogsTool)
    end

    it "includes performance diagnostics for registered Syrus forks" do
      syrus_fork = Factories.repository(user: user, owner: "acme", name: "syrus-fork", upstream_owner: "tkadauke", upstream_name: "syrus")
      syrus_run = Factories.job(repository: syrus_fork, user: user).initial_run
      context = McpToolContext.from_run(syrus_run)

      expect(described_class.for(context)).to include(SyrusMcp::ReadPerformanceDiagnosticsTool)
      expect(described_class.for(context)).to include(SyrusMcp::ReadSyrusLogsTool)
    end

    it "excludes performance diagnostics for normal non-Syrus repositories" do
      context = McpToolContext.from_run(run)

      expect(described_class.for(context)).not_to include(SyrusMcp::ReadPerformanceDiagnosticsTool)
      expect(described_class.for(context)).not_to include(SyrusMcp::ReadSyrusLogsTool)
    end

    it "excludes performance diagnostics from non-implementation workflow roles" do
      syrus_repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")
      context = McpToolContext.new(
        surface: :run,
        role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
        user: user,
        repository: syrus_repository
      )

      expect(described_class.for(context)).not_to include(SyrusMcp::ReadPerformanceDiagnosticsTool)
      expect(described_class.for(context)).not_to include(SyrusMcp::ReadSyrusLogsTool)
    end

    it "returns submit_summary, submit_test_plan, and submit_reconciliation_feedback for the reconciliation_feedback role" do
      context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK, user: user)
      tools   = described_class.for(context)

      expect(tools).to include(
        SyrusMcp::SubmitSummaryTool,
        SyrusMcp::SubmitTestPlanTool,
        SyrusMcp::SubmitReconciliationFeedbackTool
      )
      expect(tools).not_to include(SyrusMcp::SubmitAdversarialReviewTool)
    end

    it "does not include submit_reconciliation_feedback for the standard implement role" do
      context = McpToolContext.from_run(run)
      tools   = described_class.for(context)

      expect(tools).not_to include(SyrusMcp::SubmitReconciliationFeedbackTool)
    end

    it "includes submit_job_metadata for refresh_job_metadata runs" do
      run.step.update_columns(kind: "refresh_job_metadata")
      context = McpToolContext.from_run(run.reload)
      tools   = described_class.for(context)

      expect(tools).to include(SyrusMcp::SubmitJobMetadataTool)
    end

    describe ".capability_permitted?" do
      it "permits submit_summary for the implement role" do
        context = McpToolContext.from_run(run)
        expect(described_class.capability_permitted?(context, :submit_summary)).to be(true)
      end

      it "denies submit_adversarial_review for the implement role" do
        context = McpToolContext.from_run(run)
        expect(described_class.capability_permitted?(context, :submit_adversarial_review)).to be(false)
      end

      it "permits submit_adversarial_review for the adversarial_reviewer role" do
        context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
        expect(described_class.capability_permitted?(context, :submit_adversarial_review)).to be(true)
      end

      it "denies submit_summary for the adversarial_reviewer role" do
        context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
        expect(described_class.capability_permitted?(context, :submit_summary)).to be(false)
      end

      it "permits submit_chat_feedback for the reconciliation_feedback role" do
        context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK, user: user)
        expect(described_class.capability_permitted?(context, :submit_chat_feedback)).to be(true)
      end

      it "denies submit_chat_feedback for the standard implement role" do
        context = McpToolContext.from_run(run)
        expect(described_class.capability_permitted?(context, :submit_chat_feedback)).to be(false)
      end

      it "permits submit_job_metadata for the summary/test-plan role" do
        context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_SUMMARY_TEST_PLAN, user: user)
        expect(described_class.capability_permitted?(context, :submit_job_metadata)).to be(true)
      end
    end
  end

  describe "helper roles" do
    it "returns an empty tool set for every helper role" do
      AgentRole::HELPER_ROLES.each do |role|
        context = McpToolContext.new(surface: :chat, role: role, user: user)
        expect(described_class.for(context)).to be_empty, "expected [] for #{role}"
      end
    end
  end

  describe "agent insight role" do
    before do
      Feature.find_or_create_by!(slug: "agent_insights") { |f| f.category = "Labs"; f.name = "Agent Insights" }
             .update!(enabled: true)
      Feature.clear_enabled_cache!("agent_insights")
    end

    def set_operational_log_indexing(enabled)
      Feature.find_or_create_by!(slug: "operational_log_indexing") { |f| f.category = "Operations"; f.name = "Operational log indexing" }
             .update!(enabled: enabled)
      Feature.clear_enabled_cache!("operational_log_indexing")
      Current.reset
    end

    def agent_insight_context(repo = repository)
      job = Job.create!(user: user, repository: repo, kind: "agent_insight", priority: "low")
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "agent_insight",
        agent_provider: user.agent_provider,
        chain_template: []
      )
      step = Step.create!(workflow: workflow, kind: "agent_insight_run", position: 0)
      run = step.runs.create!(job: job, trigger_kind: "agent_insight", agent_provider: user.agent_provider)
      McpToolContext.from_run(run)
    end

    it "includes repository-scoped workflow evidence tools" do
      context = agent_insight_context

      expect(described_class.for(context)).to include(
        SyrusMcp::ListRecentWorkflowsTool,
        SyrusMcp::ReadInsightRunTranscriptTool,
        SyrusMcp::SubmitInsightTool
      )
      expect(described_class.for(context)).not_to include(SyrusMcp::SubmitSummaryTool, SyrusMcp::SubmitTestPlanTool)
    end

    it "includes Syrus log search for insight runs when operational logging is enabled on tkadauke/syrus" do
      set_operational_log_indexing(true)
      syrus_repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")

      expect(described_class.for(agent_insight_context(syrus_repository))).to include(SyrusMcp::ReadSyrusLogsTool)
    end

    it "includes Syrus log search for insight runs on registered Syrus forks" do
      set_operational_log_indexing(true)
      syrus_fork = Factories.repository(user: user, owner: "acme", name: "syrus-fork", upstream_owner: "tkadauke", upstream_name: "syrus")

      expect(described_class.for(agent_insight_context(syrus_fork))).to include(SyrusMcp::ReadSyrusLogsTool)
    end

    it "excludes Syrus log search for insight runs when operational logging is disabled" do
      set_operational_log_indexing(false)
      syrus_repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")

      expect(described_class.for(agent_insight_context(syrus_repository))).not_to include(SyrusMcp::ReadSyrusLogsTool)
    end

    it "excludes Syrus log search for insight runs on non-Syrus repositories" do
      set_operational_log_indexing(true)

      expect(described_class.for(agent_insight_context(repository))).not_to include(SyrusMcp::ReadSyrusLogsTool)
    end
  end

  describe "chat planner role" do
    before do
      Feature.find_or_create_by!(slug: "agent_insights") { |f| f.category = "Labs"; f.name = "Agent Insights" }
             .update!(enabled: false)
      Feature.clear_enabled_cache!("agent_insights")
    end

    it "includes essential memory tools" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools).to include(Mcp::Tools::WriteMemoryTool, Mcp::Tools::ReadMemoryTool)
    end

    it "includes deferred memory tools" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools).to include(
        Mcp::Tools::SearchMemoriesTool,
        Mcp::Tools::ListMemoriesTool,
        Mcp::Tools::DeleteMemoryTool
      )
    end

    it "excludes admin tools for non-admin users" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & SyrusChatMcp::Sidecar::ADMIN_TOOLS).to be_empty
    end

    it "includes admin tools for admin users" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin))
      context = context_for(admin_session)
      tools = described_class.for(context)

      expect(tools).to include(*SyrusChatMcp::Sidecar::ADMIN_TOOLS)
    end

    it "includes insight read tools when agent_insights is enabled" do
      Feature.find_by!(slug: "agent_insights").update!(enabled: true)
      Feature.clear_enabled_cache!("agent_insights")

      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools).to include(SyrusMcp::ListInsightsTool, SyrusMcp::ReadInsightTool)
      expect(tools).not_to include(SyrusMcp::SubmitInsightTool)
    end

    it "excludes insight read tools when agent_insights is disabled" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools).not_to include(SyrusMcp::ListInsightsTool, SyrusMcp::ReadInsightTool, SyrusMcp::SubmitInsightTool)
    end

    it "excludes coding tools" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & SyrusChatMcp::Sidecar::CODING_TOOLS).to be_empty
    end

    it "excludes local mode tools" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & SyrusChatMcp::Sidecar::LOCAL_MODE_TOOLS).to be_empty
    end

    it "excludes walkthrough tools when the feature is disabled" do
      Feature.find_or_create_by!(slug: "video_walkthroughs") { |f| f.category = "Labs"; f.name = "Walkthrough videos" }
             .update!(enabled: false)

      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & SyrusChatMcp::Sidecar::WALKTHROUGH_TOOLS).to be_empty
    end

    it "includes walkthrough tools when the feature is enabled" do
      Feature.find_or_create_by!(slug: "video_walkthroughs") { |f| f.category = "Labs"; f.name = "Walkthrough videos" }
             .update!(enabled: true)

      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & SyrusChatMcp::Sidecar::WALKTHROUGH_TOOLS).to eq(SyrusChatMcp::Sidecar::WALKTHROUGH_TOOLS)
    end
  end

  describe "chat admin role" do
    it "includes admin tools for admin supervisor chats" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin), system_kind: "supervisor")
      tools = described_class.for(context_for(admin_session))

      expect(McpToolContext.from_chat_session(admin_session).role).to eq(AgentRole::CHAT_ADMIN)
      expect(tools).to include(*SyrusChatMcp::Sidecar::ADMIN_TOOLS)
    end

    it "excludes repository attachment and work-creation tools for supervisor chats" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin), system_kind: "supervisor")
      tools = described_class.for(context_for(admin_session))

      expect(tools & described_class::SUPERVISOR_EXCLUDED_TOOLS).to be_empty
      expect(tools).to include(
        SyrusChatMcp::AdminOverviewTool,
        SyrusChatMcp::ReadQueueTool,
        SyrusChatMcp::SearchJobsTool,
        SyrusChatMcp::ReadJobTool,
        SyrusChatMcp::ListJobWorkflowsTool,
        SyrusChatMcp::ReadWorkflowTool,
        SyrusChatMcp::ReadRunTranscriptTool
      )
    end

    it "keeps repository attachment and proposal tools for ordinary admin planning chats" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin))
      tools = described_class.for(context_for(admin_session))

      expect(tools).to include(
        SyrusChatMcp::AttachRepositoryTool,
        SyrusChatMcp::ProposeEpicTool,
        SyrusChatMcp::ProposeJobTool,
        SyrusChatMcp::ProposeEpicWithJobsTool,
        SyrusChatMcp::SubmitChatFeedbackTool
      )
    end

    it "still excludes admin tools when a non-admin has a supervisor-kind session" do
      supervisor_session = chat_session(system_kind: "supervisor")
      tools = described_class.for(context_for(supervisor_session))

      expect(McpToolContext.from_chat_session(supervisor_session).role).to eq(AgentRole::CHAT_ADMIN)
      expect(tools & SyrusChatMcp::Sidecar::ADMIN_TOOLS).to be_empty
    end
  end

  describe "chat coding role" do
    before do
      Feature.find_or_create_by!(slug: "coding_mode") { |f| f.category = "Labs"; f.name = "Coding Mode" }
             .update!(enabled: true)
    end

    it "includes coding tools when feature is enabled and session is coding mode" do
      coding_session = chat_session(mode: "coding")
      context = context_for(coding_session)
      tools = described_class.for(context)

      expect(tools).to include(*SyrusChatMcp::Sidecar::CODING_TOOLS)
    end

    it "excludes coding tools when feature is disabled" do
      Feature.find_by!(slug: "coding_mode").update!(enabled: false)
      coding_session = chat_session(mode: "coding")
      context = context_for(coding_session)
      tools = described_class.for(context)

      expect(tools & SyrusChatMcp::Sidecar::CODING_TOOLS).to be_empty
    end
  end

  describe "chat local role" do
    before do
      Feature.find_or_create_by!(slug: "local_mode") { |f| f.category = "Labs"; f.name = "Local Mode" }
             .update!(enabled: true)
    end

    it "includes local mode tools when feature is enabled and session is local mode" do
      local_session = chat_session(mode: "local")
      context = context_for(local_session)
      tools = described_class.for(context)

      expect(tools).to include(*SyrusChatMcp::Sidecar::LOCAL_MODE_TOOLS)
    end

    it "excludes local mode tools when feature is disabled" do
      Feature.find_by!(slug: "local_mode").update!(enabled: false)
      local_session = chat_session(mode: "local")
      context = context_for(local_session)
      tools = described_class.for(context)

      expect(tools & SyrusChatMcp::Sidecar::LOCAL_MODE_TOOLS).to be_empty
    end
  end

  describe "output matches today's tools_for_session" do
    it "produces identical essential tool set as the sidecar for a planning session" do
      session = chat_session
      context = context_for(session)

      policy_tools = described_class.for(context).map(&:tool_name)
      sidecar_essential = SyrusChatMcp::Sidecar.tools_for(session).map(&:tool_name)

      expect(policy_tools).to include(*sidecar_essential)
    end

    it "produces identical deferred tool set as the sidecar for a planning session" do
      session = chat_session
      context = context_for(session)

      policy_tools = described_class.for(context).map(&:tool_name)
      sidecar_deferred = SyrusChatMcp::DeferredSidecar.tools_for(session).map(&:tool_name)

      expect(policy_tools).to include(*sidecar_deferred)
    end
  end
end
