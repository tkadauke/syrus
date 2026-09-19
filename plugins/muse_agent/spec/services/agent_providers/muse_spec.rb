require "rails_helper"
require "tmpdir"

RSpec.describe AgentProviders::Muse do
  before do
    PluginRecord.find_or_create_by!(name: "muse_agent").update!(enabled: true, default_enabled: false, disableable: true)
  end

  describe "plugin interface" do
    it "includes Syrus::Plugin::AgentProvider" do
      expect(described_class).to include(Syrus::Plugin::AgentProvider)
    end

    it "has provider_key 'muse'" do
      expect(described_class.provider_key).to eq("muse")
    end

    it "has display_name 'Muse Code'" do
      expect(described_class.display_name).to eq("Muse Code")
    end

    it "reports available?" do
      expect(described_class.available?).to eq(true)
    end

    it "provider_key matches provider for backward compat" do
      expect(described_class.provider_key).to eq(described_class.provider)
    end

    it "uses Muse MCP tool names" do
      expect(described_class.mcp_tool_name("submit_summary", server_name: "syrus-mcp-sidecar"))
        .to eq("mcp__syrus_mcp_sidecar__submit_summary")
    end
  end

  let(:user) { Factories.user(muse_api_key: "muse-secret") }
  let(:job) { Factories.job(user: user, agent_provider: "muse") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "muse") }
  let(:step) { Step.create!(workflow: workflow, kind: "summarize", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "muse") }
  let(:workspace) { instance_double(WorkflowWorkspace, path: "/tmp/worktree") }

  around do |ex|
    old_runner = RunJob.agent_runner
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-muse-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    ex.run
  ensure
    RunJob.agent_runner = old_runner
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  it "is configured only when the Muse API key is present" do
    expect(described_class.configured_for_user?(user)).to be true

    user.update!(muse_api_key: nil)

    expect(described_class.configured_for_user?(user)).to be false
  end

  it "invokes MuseInvocation with a per-workflow home and sidecar config" do
    received = nil
    invocation = instance_double(
      MuseInvocation,
      run: AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                       is_error: false, outcome: "success",
                                       final_text: nil, session_id: "muse-session")
    )
    allow(MuseInvocation).to receive(:new) do |workspace_path, **kwargs|
      received = kwargs.merge(workspace_path: workspace_path)
      invocation
    end

    result = described_class.new(run: run, workspace: workspace, parent_session_id: "muse-parent")
      .run(prompt: "summarize", log_sink: ->(*, **) { }, max_turns: 7, required_mcp_tools: %w[submit_summary])

    expect(result).to be_success
    expect(received).to include(
      workspace_path: "/tmp/worktree",
      prompt: "summarize",
      api_key: "muse-secret",
      session_id: "muse-parent",
      max_model_steps: 7,
      required_mcp_tools: %w[submit_summary]
    )
    expect(received[:muse_home].to_s).to eq(WorkflowWorkspace.agent_home_for(workflow, "muse").to_s)
    expect(received[:mcp_server]).to include(
      "syrus-mcp-sidecar" => include(
        command: a_string_ending_with("/bin/syrus-mcp-sidecar"),
        args: [ "--run-id", run.id.to_s ],
        env: include("SYRUS_DATA_ROOT" => ENV.fetch("SYRUS_DATA_ROOT"))
      )
    )
  end
end
