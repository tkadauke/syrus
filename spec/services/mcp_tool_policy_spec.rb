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
        SyrusMcp::SubmitSummaryTool,
        SyrusMcp::SubmitTestPlanTool,
        SyrusMcp::ReportMainConcernTool
      )
      expect(tools).not_to include(SyrusMcp::SubmitAdversarialReviewTool)
      expect(tools.size).to eq(10)
    end

    it "returns submit_adversarial_review but not submit_summary for the adversarial_reviewer role" do
      context = McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, user: user)
      tools   = described_class.for(context)

      expect(tools).to include(SyrusMcp::ReadLiveStateTool, SyrusMcp::SubmitAdversarialReviewTool)
      expect(tools).not_to include(SyrusMcp::SubmitSummaryTool, SyrusMcp::SubmitTestPlanTool)
      expect(tools.size).to eq(9)
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

  describe "chat planner role" do
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
