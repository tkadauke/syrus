require "rails_helper"
require "tmpdir"

RSpec.describe AgentProviders::Claude do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:job) { Factories.job(user: user) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }
  let(:workspace) { instance_double(WorkflowWorkspace, path: "/tmp/worktree") }

  def adapter(parent_session_id: "S-parent")
    described_class.new(run: run, workspace: workspace, parent_session_id: parent_session_id)
  end

  around do |ex|
    old_runner = RunJob.agent_runner
    ex.run
  ensure
    RunJob.agent_runner = old_runner
  end

  describe "#run" do
    around do |ex|
      stash = {
        "RAILS_ENV" => "production",
        "RAILS_MASTER_KEY" => "deadbeef",
        "SECRET_KEY_BASE" => "secretsecret",
        "DB_HOST" => "syrus-mysql",
        "SYRUS_DATABASE_PASSWORD" => "swordfish",
        "BUNDLE_PATH" => "/usr/local/bundle",
        "BUNDLE_DEPLOYMENT" => "1",
        "BUNDLE_WITHOUT" => "development:test",
        "TZ" => "America/New_York"
      }
      saved = ENV.to_h.slice(*stash.keys)
      stash.each { |k, v| ENV[k] = v }
      ex.run
    ensure
      stash.keys.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
    end

    it "invokes AgentInvocation with Claude-specific MCP config" do
      received = nil
      mcp_config = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        mcp_config = JSON.parse(File.read(kwargs[:mcp_config]))
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
                                    final_text: nil, session_id: nil)
      }

      result = adapter.run(prompt: "do it", log_sink: ->(*, **) { }, max_turns: 7)

      expect(result).to be_success
      expect(received).to include(
        workspace_path: "/tmp/worktree",
        prompt: "do it",
        oauth_token: "oat-test",
        max_turns: 7,
        resume_session_id: "S-parent"
      )
      server = mcp_config.dig("mcpServers", "syrus-mcp-sidecar")
      expect(server["command"]).to end_with("/bin/syrus-mcp-sidecar")
      expect(server["args"]).to eq([ "--run-id", run.id.to_s ])
      expect(server["alwaysLoad"]).to be(true)
      expect(server["env"]).to include(
        "RAILS_ENV" => "production",
        "RAILS_MASTER_KEY" => "deadbeef",
        "BUNDLE_WITHOUT" => "development:test"
      )
    end
  end

  describe "#session_capture" do
    it "reads Claude's canonical JSONL path when the invocation result did not include transcript data" do
      Dir.mktmpdir do |home|
        saved_home = ENV["HOME"]
        ENV["HOME"] = home
        path = ClaudeSession.canonical_path_for(
          home: home,
          cwd: workspace.path,
          session_id: "S-captured"
        )
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "{\"type\":\"system\"}\n")
        result = AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                             is_error: false, outcome: "success",
                                             final_text: nil, session_id: "S-captured")

        capture = adapter.session_capture(result)

        expect(capture.provider).to eq("claude")
        expect(capture.session_id).to eq("S-captured")
        expect(capture.transcript_jsonl).to include("system")
        expect(capture.missing_message).to be_nil
      ensure
        ENV["HOME"] = saved_home
      end
    end
  end
end
