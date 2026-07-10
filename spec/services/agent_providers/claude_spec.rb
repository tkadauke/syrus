require "rails_helper"
require "tmpdir"

RSpec.describe AgentProviders::Claude do
  describe "plugin interface" do
    it "includes Syrus::Plugin::AgentProvider" do
      expect(described_class).to include(Syrus::Plugin::AgentProvider)
    end

    it "has provider_key 'claude'" do
      expect(described_class.provider_key).to eq("claude")
    end

    it "has display_name 'Claude Code'" do
      expect(described_class.display_name).to eq("Claude Code")
    end

    it "reports available?" do
      expect(described_class.available?).to eq(true)
    end

    it "provider_key matches provider for backward compat" do
      expect(described_class.provider_key).to eq(described_class.provider)
    end
  end

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
        "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary",
        "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "deterministic",
        "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "salt",
        "SECRET_KEY_BASE" => "secretsecret",
        "RAILS_LOG_LEVEL" => "info",
        "DATABASE_URL" => "sqlite3:///home/rails/.syrus/db/production.sqlite3",
        "DB_HOST" => "syrus-mysql",
        "SYRUS_DATABASE_PASSWORD" => "swordfish",
        "SYRUS_SQLITE" => "1",
        "SYRUS_DATA_ROOT" => "/home/rails/.syrus",
        "BUNDLE_PATH" => "/usr/local/bundle",
        "PATH" => "/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin",
        "GEM_HOME" => "/usr/local/bundle",
        "GEM_PATH" => "/usr/local/bundle",
        "BUNDLE_DEPLOYMENT" => "1",
        "BUNDLE_WITHOUT" => "development:test",
        "TZ" => "America/New_York",
        "SYRUS_APP_HOST" => "syrus.example.test",
        "SYRUS_ALLOWED_HOSTS" => "syrus.example.test,syrus.internal.test",
        "SYRUS_ASSUME_SSL" => "true",
        "SYRUS_FORCE_SSL" => "true",
        "S3_BUCKET" => "syrus-attachments",
        "S3_ENDPOINT" => "http://minio.minio.svc.cluster.local:9000",
        "S3_REGION" => "us-east-1",
        "S3_ACCESS_KEY_ID" => "ak",
        "S3_SECRET_ACCESS_KEY" => "sk"
      }
      saved = ENV.to_h.slice(*stash.keys)
      stash.each { |k, v| ENV[k] = v }
      ex.run
    ensure
      stash.keys.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
    end

    it "invokes ClaudeInvocation with Claude-specific MCP config" do
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
        # Production containers may use ACTIVE_RECORD_ENCRYPTION_* instead of
        # RAILS_MASTER_KEY; MCP children must inherit whichever mode the worker
        # is using so encrypted credentials can be read during boot.
        "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary",
        "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "deterministic",
        "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "salt",
        # Docker Compose local mode runs production against SQLite files under
        # SYRUS_DATA_ROOT. Without these, the sidecar falls back to MySQL and
        # dies before replying to the MCP initialize request.
        "SYRUS_SQLITE" => "1",
        "SYRUS_DATA_ROOT" => "/home/rails/.syrus",
        "DATABASE_URL" => "sqlite3:///home/rails/.syrus/db/production.sqlite3",
        "PATH" => "/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin",
        "BUNDLE_WITHOUT" => "development:test",
        # Sidecar boots Rails production config; SYRUS_APP_HOST is
        # required at boot now that production has no baked-in host
        # default. Related host/SSL knobs should also cross the same
        # subprocess boundary so sidecar behavior matches the worker.
        "SYRUS_APP_HOST" => "syrus.example.test",
        "SYRUS_ALLOWED_HOSTS" => "syrus.example.test,syrus.internal.test",
        "SYRUS_ASSUME_SSL" => "true",
        "SYRUS_FORCE_SSL" => "true",
        # Sidecar boots Rails in production where eager_load triggers
        # Active Storage's S3Service.new at boot; the S3_* vars must
        # reach the subprocess or `Aws::S3::Resource#bucket(nil)`
        # raises and the sidecar dies before responding to claude's
        # MCP initialize handshake.
        "S3_BUCKET" => "syrus-attachments",
        "S3_ENDPOINT" => "http://minio.minio.svc.cluster.local:9000",
        "S3_REGION" => "us-east-1",
        "S3_ACCESS_KEY_ID" => "ak",
        "S3_SECRET_ACCESS_KEY" => "sk"
      )
    end

    it "persists live_session_id on the Run when on_session_id callback fires" do
      RunJob.agent_runner = ->(**kwargs) {
        kwargs[:on_session_id].call("sid-live-abc")
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
                                    final_text: nil, session_id: "sid-live-abc")
      }

      adapter.run(prompt: "do it", log_sink: ->(*, **) {}, max_turns: 5)

      expect(run.reload.live_session_id).to eq("sid-live-abc")
    end
  end

  describe "#run_once" do
    it "uses a tmpdir without MCP or resume state" do
      received = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
                                    final_text: '{"title":"x","body":"y"}',
                                    session_id: nil)
      }

      result = adapter.run_once(prompt: "summarize",
                                log_sink: ->(*, **) { },
                                timeout: 9,
                                max_turns: 1)

      expect(result).to be_success
      expect(received[:workspace_path]).to start_with(Dir.tmpdir)
      expect(received).to include(
        prompt: "summarize",
        oauth_token: "oat-test",
        timeout: 9,
        max_turns: 1,
        mcp_config: nil,
        resume_session_id: nil
      )
    end
  end

  describe "#record_result!" do
    it "persists cost and token usage from the invocation result" do
      result = AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: nil,
        session_id: nil,
        cost_usd: 0.123456,
        input_tokens: 100,
        output_tokens: 20,
        cache_creation_input_tokens: 30,
        cache_read_input_tokens: 400
      )

      adapter.record_result!(result, log: ->(*) { })

      run.reload
      expect(run.cost_usd).to eq(BigDecimal("0.123456"))
      expect(run.input_tokens).to eq(100)
      expect(run.output_tokens).to eq(20)
      expect(run.cache_creation_input_tokens).to eq(30)
      expect(run.cache_read_input_tokens).to eq(400)
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

    it "does not read a transcript path for an unsafe session id" do
      result = AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                           is_error: false, outcome: "success",
                                           final_text: nil, session_id: "../outside")

      expect(File).not_to receive(:read)

      capture = adapter.session_capture(result)

      expect(capture.provider).to eq("claude")
      expect(capture.session_id).to eq("../outside")
      expect(capture.transcript_jsonl).to be_nil
      expect(capture.missing_message).to include("invalid Claude session id")
    end
  end
end
