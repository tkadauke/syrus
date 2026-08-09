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
        Mcp::Tools::ReadLiveStateTool,
        Mcp::Tools::ReadMemoryTool,
        Mcp::Tools::WriteMemoryTool,
        Mcp::Tools::DeleteMemoryTool,
        Mcp::Tools::SearchMemoriesTool,
        Mcp::Tools::ListMemoriesTool,
        Mcp::Tools::GetCoverageReportTool,
        Mcp::Tools::ReadRunWorkerHealthTool,
        Mcp::Tools::StartPreviewTool,
        Mcp::Tools::StopPreviewTool,
        Mcp::Tools::ReadPreviewLogTool,
        Mcp::Tools::SubmitSummaryTool,
        Mcp::Tools::SubmitTestPlanTool,
        SyrusMcp::SubmitArtifactTool,
        Mcp::Tools::ReportMainConcernTool
      )
      expect(tools).not_to include(Mcp::Tools::SubmitAdversarialReviewTool, Mcp::Tools::SubmitJobMetadataTool)
      expect(tools.size).to eq(15)
    end

    it "returns submit_adversarial_review but not submit_summary for the adversarial_reviewer role" do
      context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
      tools   = described_class.for(context)

      expect(tools).to include(
        Mcp::Tools::ReadLiveStateTool,
        Mcp::Tools::ReadRunWorkerHealthTool,
        Mcp::Tools::SubmitAdversarialReviewTool
      )
      expect(tools).not_to include(Mcp::Tools::SubmitSummaryTool, Mcp::Tools::SubmitTestPlanTool)
      expect(tools.size).to eq(12)
    end

    it "excludes report_main_concern from the adversarial_reviewer role" do
      context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
      tools   = described_class.for(context)

      expect(tools).not_to include(Mcp::Tools::ReportMainConcernTool)
    end

    it "includes report_main_concern for the implement role" do
      context = McpToolContext.from_run(run)
      tools   = described_class.for(context)

      expect(tools).to include(Mcp::Tools::ReportMainConcernTool)
    end

    it "does not include workflow-side submit_chat_feedback for the standard implement role" do
      context = McpToolContext.from_run(run)
      tools   = described_class.for(context)

      expect(tools.map(&:tool_name)).not_to include("submit_chat_feedback")
    end

    it "includes submit_job_metadata for refresh_job_metadata runs" do
      run.step.update_columns(kind: "refresh_job_metadata")
      context = McpToolContext.from_run(run.reload)
      tools   = described_class.for(context)

      expect(tools).to include(Mcp::Tools::SubmitJobMetadataTool)
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

      it "denies submit_chat_feedback for the standard implement role" do
        context = McpToolContext.from_run(run)
        expect(described_class.capability_permitted?(context, :submit_chat_feedback)).to be(false)
      end

      it "permits submit_job_metadata for the summary/test-plan role" do
        context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_SUMMARY_TEST_PLAN, user: user)
        expect(described_class.capability_permitted?(context, :submit_job_metadata)).to be(true)
      end

      it "permits submit_artifact for the implement role" do
        context = McpToolContext.from_run(run)
        expect(described_class.capability_permitted?(context, :submit_artifact)).to be(true)
      end

      it "denies submit_artifact for the adversarial_reviewer role" do
        context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
        expect(described_class.capability_permitted?(context, :submit_artifact)).to be(false)
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
        Mcp::Tools::ListRecentWorkflowsTool,
        Mcp::Tools::ReadInsightRunTranscriptTool,
        Mcp::Tools::SubmitInsightTool
      )
      expect(described_class.for(context)).not_to include(Mcp::Tools::SubmitSummaryTool, Mcp::Tools::SubmitTestPlanTool)
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

      expect(tools & Mcp::Sidecar::CHAT_ADMIN_TOOLS).to be_empty
    end

    it "includes admin tools for admin users" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin))
      context = context_for(admin_session)
      tools = described_class.for(context)

      expect(tools).to include(*Mcp::Sidecar::CHAT_ADMIN_TOOLS)
    end

    it "includes insight read tools when agent_insights is enabled" do
      Feature.find_by!(slug: "agent_insights").update!(enabled: true)
      Feature.clear_enabled_cache!("agent_insights")

      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools).to include(Mcp::Tools::ListInsightsTool, Mcp::Tools::ReadInsightTool)
      expect(tools).not_to include(Mcp::Tools::SubmitInsightTool)
    end

    it "excludes insight read tools when agent_insights is disabled" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools).not_to include(Mcp::Tools::ListInsightsTool, Mcp::Tools::ReadInsightTool, Mcp::Tools::SubmitInsightTool)
    end

    it "excludes coding tools" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & Mcp::Sidecar::CHAT_CODING_TOOLS).to be_empty
    end

    it "excludes local mode tools" do
      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & Mcp::Sidecar::CHAT_LOCAL_MODE_TOOLS).to be_empty
    end

    it "excludes walkthrough tools when the feature is disabled" do
      Feature.find_or_create_by!(slug: "video_walkthroughs") { |f| f.category = "Labs"; f.name = "Walkthrough videos" }
             .update!(enabled: false)

      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & Mcp::Sidecar::CHAT_WALKTHROUGH_TOOLS).to be_empty
    end

    it "includes walkthrough tools when the feature is enabled" do
      Feature.find_or_create_by!(slug: "video_walkthroughs") { |f| f.category = "Labs"; f.name = "Walkthrough videos" }
             .update!(enabled: true)

      context = context_for(chat_session)
      tools = described_class.for(context)

      expect(tools & Mcp::Sidecar::CHAT_WALKTHROUGH_TOOLS).to eq(Mcp::Sidecar::CHAT_WALKTHROUGH_TOOLS)
    end
  end

  describe "chat admin role" do
    it "includes admin tools for admin supervisor chats" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin), system_kind: "supervisor")
      tools = described_class.for(context_for(admin_session))

      expect(McpToolContext.from_chat_session(admin_session).role).to eq(AgentRole::CHAT_ADMIN)
      expect(tools).to include(*Mcp::Sidecar::CHAT_ADMIN_TOOLS)
    end

    it "excludes repository attachment and work-creation tools for supervisor chats" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin), system_kind: "supervisor")
      tools = described_class.for(context_for(admin_session))

      expect(tools & described_class::SUPERVISOR_EXCLUDED_TOOLS).to be_empty
      expect(tools).to include(
        Mcp::Tools::AdminOverviewTool,
        Mcp::Tools::ReadQueueTool,
        Mcp::Tools::SearchJobsTool,
        Mcp::Tools::ReadJobTool,
        Mcp::Tools::ListJobWorkflowsTool,
        Mcp::Tools::ReadWorkflowTool,
        Mcp::Tools::ReadRunTranscriptTool
      )
    end

    it "keeps repository attachment and proposal tools for ordinary admin planning chats" do
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin))
      tools = described_class.for(context_for(admin_session))

      expect(tools).to include(
        Mcp::Tools::AttachRepositoryTool,
        Mcp::Tools::ProposeEpicTool,
        Mcp::Tools::ProposeJobTool,
        Mcp::Tools::ProposeEpicWithJobsTool,
        Mcp::Tools::SubmitChatFeedbackTool
      )
    end

    it "still excludes admin tools when a non-admin has a supervisor-kind session" do
      supervisor_session = chat_session(system_kind: "supervisor")
      tools = described_class.for(context_for(supervisor_session))

      expect(McpToolContext.from_chat_session(supervisor_session).role).to eq(AgentRole::CHAT_ADMIN)
      expect(tools & Mcp::Sidecar::CHAT_ADMIN_TOOLS).to be_empty
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

      expect(tools).to include(*Mcp::Sidecar::CHAT_CODING_TOOLS)
    end

    it "excludes coding tools when feature is disabled" do
      Feature.find_by!(slug: "coding_mode").update!(enabled: false)
      coding_session = chat_session(mode: "coding")
      context = context_for(coding_session)
      tools = described_class.for(context)

      expect(tools & Mcp::Sidecar::CHAT_CODING_TOOLS).to be_empty
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

      expect(tools).to include(*Mcp::Sidecar::CHAT_LOCAL_MODE_TOOLS)
    end

    it "excludes local mode tools when feature is disabled" do
      Feature.find_by!(slug: "local_mode").update!(enabled: false)
      local_session = chat_session(mode: "local")
      context = context_for(local_session)
      tools = described_class.for(context)

      expect(tools & Mcp::Sidecar::CHAT_LOCAL_MODE_TOOLS).to be_empty
    end
  end

  describe "output matches today's tools_for_session" do
    it "produces identical essential tool set as the sidecar for a planning session" do
      session = chat_session
      context = context_for(session)

      policy_tools = described_class.for(context).map(&:tool_name)
      sidecar_essential = Mcp::Sidecar.chat_tools(session, tier: :essential).map(&:tool_name)

      expect(policy_tools).to include(*sidecar_essential)
    end

    it "produces identical deferred tool set as the sidecar for a planning session" do
      session = chat_session
      context = context_for(session)

      policy_tools = described_class.for(context).map(&:tool_name)
      sidecar_deferred = Mcp::Sidecar.chat_tools(session, tier: :deferred).map(&:tool_name)

      expect(policy_tools).to include(*sidecar_deferred)
    end
  end
end
