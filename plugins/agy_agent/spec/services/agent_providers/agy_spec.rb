require "rails_helper"
require "tmpdir"

RSpec.describe AgentProviders::Agy do
  describe "plugin interface" do
    it "includes Syrus::Plugin::AgentProvider" do
      expect(described_class).to include(Syrus::Plugin::AgentProvider)
    end

    it "has provider_key 'agy'" do
      expect(described_class.provider_key).to eq("agy")
    end

    it "has display_name 'Antigravity'" do
      expect(described_class.display_name).to eq("Antigravity")
    end

    it "reports available?" do
      expect(described_class.available?).to eq(true)
    end

    it "provider_key matches provider for backward compat" do
      expect(described_class.provider_key).to eq(described_class.provider)
    end
  end

  let(:user) { Factories.user }
  let(:job) { Factories.job(user: user) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }
  let(:workspace) { instance_double(WorkflowWorkspace, path: "/tmp/worktree") }

  around do |ex|
    old_runner = RunJob.agent_runner
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-agy-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    ex.run
  ensure
    RunJob.agent_runner = old_runner
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  it "invokes AgyInvocation with an isolated workflow provider home" do
    received = nil
    RunJob.agent_runner = ->(**kwargs) {
      received = kwargs
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: nil,
        session_id: "agy-session"
      )
    }

    result = described_class.new(run: run, workspace: workspace, parent_session_id: "parent-1")
                            .run(prompt: "do it", log_sink: ->(*, **) { })

    expect(result).to be_success
    expect(received).to include(
      workspace_path: "/tmp/worktree",
      prompt: "do it",
      resume_session_id: "parent-1"
    )
    expect(received[:agy_home]).to eq(WorkflowWorkspace.agent_home_for(workflow, "agy").to_s)
  end
end
