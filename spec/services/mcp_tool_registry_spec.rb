require "rails_helper"

RSpec.describe McpToolRegistry do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def chat_session(session_user: user, session_repository: repository, **attrs)
    ChatSession.create!({ user: session_user, repository: session_repository }.merge(attrs))
  end

  def tool_names_for(context, tier: nil)
    described_class.tools_for_context(context, tier: tier).map(&:tool_name)
  end

  def enable_feature(slug)
    Feature.find_or_create_by!(slug: slug.to_s) { |feature| feature.category = "Labs"; feature.name = slug.to_s.humanize }
           .update!(enabled: true)
  end

  describe ".summaries" do
    it "exposes introspectable metadata for docs and usage payloads" do
      summary = described_class.summaries(surface: :chat, tier: :essential).find { |entry| entry[:tool_name] == "submit_chat_feedback" }

      expect(summary).to include(
        surface: :chat,
        tier: :essential,
        admin_only: false,
        mutation: true,
        read_only: false
      )
      expect(summary).to include(:feature_flag, :required_roles, :capability, :tool)
    end
  end

  describe ".tools_for_context" do
    it "keeps the planner chat tool set unchanged" do
      session = chat_session
      context = McpToolContext.from_chat_session(session)

      expect(tool_names_for(context, tier: :essential)).to eq(SyrusChatMcp::Sidecar.tool_names(session, tier: :essential))
      expect(tool_names_for(context, tier: :deferred)).to eq(SyrusChatMcp::DeferredSidecar.tool_names(session))
    end

    it "keeps the admin chat tool set unchanged" do
      admin = Factories.user(admin: true)
      session = chat_session(session_user: admin, session_repository: Factories.repository(user: admin))
      context = McpToolContext.from_chat_session(session)

      expect(tool_names_for(context, tier: :essential)).to eq(SyrusChatMcp::Sidecar.tool_names(session, tier: :essential))
      expect(tool_names_for(context, tier: :essential)).to include("admin_overview", "force_fail_job")
    end

    it "keeps the coding chat tool set gated by role and feature flag" do
      enable_feature(:coding_mode)
      session = chat_session(mode: "coding")
      context = McpToolContext.from_chat_session(session)

      expect(tool_names_for(context, tier: :essential)).to include("complete_implement_step", "submit_coding_changes")
      expect(tool_names_for(context, tier: :essential)).to eq(SyrusChatMcp::Sidecar.tool_names(session, tier: :essential))
    end

    it "keeps the local mode chat tool set gated by role and feature flag" do
      enable_feature(:local_mode)
      session = chat_session(mode: "local")
      context = McpToolContext.from_chat_session(session)

      expect(tool_names_for(context, tier: :essential)).to include("read_file", "write_file", "run_command", "git_status")
      expect(tool_names_for(context, tier: :essential)).to eq(SyrusChatMcp::Sidecar.tool_names(session, tier: :essential))
    end

    it "keeps the workflow implementation tool set unchanged" do
      run = Factories.job.initial_run
      context = McpToolContext.from_run(run)

      expect(described_class.tools_for_context(context)).to eq(McpToolPolicy.for(context))
      expect(tool_names_for(context)).to contain_exactly(
        *%w[read_live_state read_memory write_memory delete_memory search_memories list_memories get_coverage_report report_main_concern submit_summary submit_test_plan]
      )
    end

    it "keeps the adversarial reviewer tool set unchanged" do
      run = Factories.job.initial_run
      run.step.update_columns(kind: "adversarial_review")
      context = McpToolContext.from_run(run.reload)

      expect(tool_names_for(context)).to contain_exactly(
        *%w[read_live_state read_memory write_memory delete_memory search_memories list_memories get_coverage_report report_main_concern submit_adversarial_review]
      )
    end

    it "keeps agent insight tools gated by feature flag" do
      run = Factories.job.initial_run
      run.step.update_columns(kind: "agent_insight_run")

      disabled_context = McpToolContext.from_run(run.reload)
      expect(tool_names_for(disabled_context)).not_to include("submit_insight", "list_insights", "read_insight")

      enable_feature(:agent_insights)

      enabled_context = McpToolContext.from_run(run.reload)
      expect(tool_names_for(enabled_context)).to include("submit_insight", "list_insights", "read_insight")
    end
  end

  it "has one metadata entry for every chat MCP tool file" do
    sidecar_tool_names = Dir[Rails.root.join("app/services/syrus_chat_mcp/*_tool.rb")]
      .map { |path| File.basename(path, ".rb").sub(/_tool\z/, "") }
    shared_tool_names = Dir[Rails.root.join("app/services/mcp/tools/*_tool.rb")]
      .map { |path| File.basename(path, ".rb").sub(/_tool\z/, "") }

    registry_names = described_class.summaries(surface: :chat).map { |entry| entry[:tool_name] }

    expect(registry_names.sort).to eq((sidecar_tool_names + shared_tool_names).sort)
  end
end
