require "rails_helper"

RSpec.describe AgentInvocation do
  def result_fixture(**overrides)
    defaults = { turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil }
    AgentInvocation::Result.new(**defaults.merge(overrides), session_id: nil)
  end

  describe "#run" do
    it "delegates to the injected runner with all the kwargs" do
      received = {}
      runner = ->(**kwargs) {
        received.merge!(kwargs)
        result_fixture(turns: 2)
      }

      result = described_class.new("/tmp/wkt", prompt: "do the thing", oauth_token: "oat-x",
                                   runner: runner, timeout: 60, max_turns: 7).run

      expect(received[:workspace_path]).to eq("/tmp/wkt")
      expect(received[:prompt]).to eq("do the thing")
      expect(received[:oauth_token]).to eq("oat-x")
      expect(received[:timeout]).to eq(60)
      expect(received[:max_turns]).to eq(7)
      expect(received[:mcp_config]).to be_nil
      expect(received[:stop_requested].call).to eq(false)
      expect(result.turns).to eq(2)
      expect(result).to be_success
    end

    it "passes mcp_config through to the runner when set" do
      received = {}
      runner = ->(**kwargs) {
        received.merge!(kwargs)
        result_fixture
      }

      described_class.new("/tmp/wkt", prompt: "x", oauth_token: "x",
                          runner: runner, mcp_config: "/tmp/mcp.json").run

      expect(received[:mcp_config]).to eq("/tmp/mcp.json")
    end
  end

  describe AgentInvocation::Result do
    it "is success when not timed out, exit_status 0, and not is_error" do
      r = described_class.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      expect(r).to be_success
    end

    it "is not success when timed_out" do
      r = described_class.new(turns: 30, exit_status: nil, timed_out: true, is_error: false, outcome: nil, final_text: nil, session_id: nil)
      expect(r).not_to be_success
    end

    it "is not success when exit_status non-zero" do
      r = described_class.new(turns: 1, exit_status: 1, timed_out: false, is_error: false, outcome: nil, final_text: nil, session_id: nil)
      expect(r).not_to be_success
    end

    it "is not success when is_error is true (e.g. error_max_turns)" do
      r = described_class.new(turns: 50, exit_status: 0, timed_out: false, is_error: true, outcome: "error_max_turns", final_text: nil, session_id: nil)
      expect(r).not_to be_success
    end
  end

  describe "stream-json event parsing" do
    let(:lines) { [] }
    let(:invocation) { described_class.new("/tmp", prompt: "x", oauth_token: "x", log_sink: ->(l, **_) { lines << l }) }

    it "extracts assistant text into the log_sink" do
      event = { type: "assistant", message: { content: [ { type: "text", text: "Looking at the issue..." } ] } }.to_json
      result = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(lines.last).to eq("Looking at the issue...")
      expect(result).to be_nil
    end

    it "captures num_turns + is_error + outcome from the result event" do
      event = { type: "result", num_turns: 5, duration_ms: 12345, is_error: false, subtype: "success" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to eq(turns: 5, is_error: false, outcome: "success", final_text: nil)
      expect(lines.last).to match(/subtype=success/).and match(/turns=5/)
    end

    it "captures cost and token usage from the result event" do
      event = {
        type: "result",
        num_turns: 5,
        duration_ms: 12345,
        is_error: false,
        subtype: "success",
        total_cost_usd: 0.1234,
        usage: {
          input_tokens: 100,
          output_tokens: 20,
          cache_creation_input_tokens: 30,
          cache_read_input_tokens: 400
        }
      }.to_json

      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })

      expect(update).to include(
        cost_usd: 0.1234,
        input_tokens: 100,
        output_tokens: 20,
        cache_creation_input_tokens: 30,
        cache_read_input_tokens: 400
      )
    end

    it "captures error subtype on max-turns" do
      event = { type: "result", num_turns: 50, is_error: true, subtype: "error_max_turns" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to include(is_error: true, outcome: "error_max_turns", final_text: nil)
    end

    it "passes non-JSON lines through verbatim" do
      result = invocation.send(:process_event, "not json", ->(l, **_) { lines << l })
      expect(lines.last).to eq("not json")
      expect(result).to be_nil
    end

    it "ignores unknown event types" do
      event = { type: "unknown", foo: "bar" }.to_json
      result = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(lines).to be_empty
      expect(result).to be_nil
    end

    it "captures session_id from the system/init event" do
      event = { type: "system", subtype: "init", session_id: "abc-123-xyz", cwd: "/x" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to eq(session_id: "abc-123-xyz")
    end

    it "ignores other system subtypes (only system/init carries the session_id we need)" do
      event = { type: "system", subtype: "other", session_id: "xxx" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to be_nil
    end
  end

  describe "default_runner cmd line ordering" do
    # `claude --mcp-config <configs...>` is variadic and will swallow
    # the next positional arg as a second config. If `--mcp-config <path>`
    # ends up immediately before the prompt, claude prepends cwd to the
    # prompt and bails with ENAMETOOLONG. This regression test pins the
    # ordering: --mcp-config must always be followed by another flag,
    # never by the prompt directly.
    it "places --mcp-config before another flag, not directly before the prompt" do
      invocation = described_class.new("/tmp", prompt: "PROMPT_BODY", oauth_token: "x",
                                       mcp_config: "/tmp/mcp.json")

      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      invocation.run

      mcp_idx    = cmd.index("--mcp-config")
      prompt_idx = cmd.index("PROMPT_BODY")
      expect(mcp_idx).not_to be_nil, "expected --mcp-config in cmd: #{cmd.inspect}"
      expect(cmd[mcp_idx + 1]).to eq("/tmp/mcp.json")
      expect(cmd[mcp_idx + 2]).to start_with("--"),
        "arg after mcp-config path must be another flag, not a positional — got #{cmd[mcp_idx + 2].inspect}"
      expect(prompt_idx).to eq(cmd.length - 1)  # prompt is the last positional
    end

    it "passes --resume <id> when resume_session_id is set" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x",
                                       resume_session_id: "abc-123")
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      invocation.run

      idx = cmd.index("--resume")
      expect(idx).not_to be_nil, "expected --resume in cmd: #{cmd.inspect}"
      expect(cmd[idx + 1]).to eq("abc-123")
      expect(cmd[idx + 2]).to start_with("--"), "arg after resume id must be another flag — got #{cmd[idx + 2].inspect}"
    end

    it "omits --resume when resume_session_id is nil (default)" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--resume")
    end

    it "passes --max-turns <n> when max_turns is positive" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", max_turns: 42)
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      invocation.run
      idx = cmd.index("--max-turns")
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq("42")
    end

    it "omits --max-turns entirely when max_turns is 0 (operator opted out of the cap)" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", max_turns: 0)
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--max-turns")
    end

    it "omits --max-turns when max_turns is nil" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", max_turns: nil)
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--max-turns")
    end
  end

  describe "agent env isolation (issue #104)" do
    # Stash + restore process-wide ENV so each example sees the same
    # baseline. ENV is global state; we set a worker-pod-like baseline,
    # run the example, then restore. Avoids depending on the host's
    # actual env for assertions.
    let(:saved_env) { ENV.to_h }
    let(:worker_baseline) do
      {
        # Worker-pod-like leakers we expect Syrus to STRIP:
        "BUNDLE_GEMFILE"          => "/rails/Gemfile",
        "BUNDLE_PATH"             => "/usr/local/bundle",
        "BUNDLE_DEPLOYMENT"       => "1",
        "BUNDLE_WITHOUT"          => "development:test",
        "GEM_HOME"                => "/usr/local/bundle",
        "GEM_PATH"                => "/usr/local/bundle",
        "RAILS_ENV"               => "production",
        "RAILS_MASTER_KEY"        => "should-never-leak",
        "SYRUS_DATABASE_PASSWORD" => "also-should-never-leak",
        # Allowlisted vars Syrus should FORWARD:
        "HOME"                    => "/home/rails",
        "PATH"                    => "/usr/local/bin:/usr/bin:/bin",
        "LANG"                    => "C.UTF-8"
      }
    end

    before do
      ENV.replace(saved_env.merge(worker_baseline))
    end
    after { ENV.replace(saved_env) }

    # Capture env + spawn opts so we can assert on them.
    def with_capturing_popen
      captured = { env: nil, opts: nil }
      allow(Open3).to receive(:popen2e) do |env, *_args, **opts, &blk|
        captured[:env] = env
        captured[:opts] = opts
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end
      yield
      captured
    end

    it "passes unsetenv_others: true so the worker env doesn't leak into the agent" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      result = with_capturing_popen { invocation.run }
      expect(result[:opts][:unsetenv_others]).to be true
    end

    it "drops worker container's BUNDLE_*/RAILS_*/GEM_* vars from the child env" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      result = with_capturing_popen { invocation.run }
      env = result[:env]
      %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_DEPLOYMENT BUNDLE_WITHOUT
         GEM_HOME GEM_PATH RAILS_ENV RAILS_MASTER_KEY SYRUS_DATABASE_PASSWORD].each do |k|
        expect(env).not_to have_key(k), "expected #{k.inspect} to be stripped from agent env, got #{env.inspect}"
      end
    end

    it "forwards CLAUDE_CODE_OAUTH_TOKEN" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "oat-secret")
      result = with_capturing_popen { invocation.run }
      expect(result[:env]["CLAUDE_CODE_OAUTH_TOKEN"]).to eq("oat-secret")
    end

    it "forwards a curated allowlist of basic shell vars" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      result = with_capturing_popen { invocation.run }
      env = result[:env]
      expect(env["HOME"]).to eq("/home/rails")
      expect(env["PATH"]).to eq("/usr/local/bin:/usr/bin:/bin")
      expect(env["LANG"]).to eq("C.UTF-8")
    end

    it "sets BUNDLE_GEMFILE to the worktree's Gemfile when one exists" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\n")
        invocation = described_class.new(dir, prompt: "P", oauth_token: "x")
        result = with_capturing_popen { invocation.run }
        expect(result[:env]["BUNDLE_GEMFILE"]).to eq(File.join(dir, "Gemfile"))
      end
    end

    it "leaves BUNDLE_GEMFILE unset when the worktree has no Gemfile (non-Ruby project)" do
      Dir.mktmpdir do |dir|
        invocation = described_class.new(dir, prompt: "P", oauth_token: "x")
        result = with_capturing_popen { invocation.run }
        expect(result[:env]).not_to have_key("BUNDLE_GEMFILE")
      end
    end
  end
end
