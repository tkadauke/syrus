require "rails_helper"

RSpec.describe Steps::Base do
  let(:job)      { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step)     { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let(:run)      do
    Run.create!(job: job, step: step, trigger_kind: "initial").tap { |r| r.start!; r.save! }
  end

  # Concrete subclass so we can exercise Base's helpers without
  # invoking real handlers' git/claude side-effects.
  let(:handler_class) do
    Class.new(described_class) do
      def call; nil; end
      public :log, :parent_session_id, :buffered_log_sink, :agent_provider,
             :agent_adapter, :perform_agentic_change_step, :commit_agent_changes
    end
  end
  let(:handler) { handler_class.new(run) }

  describe "#log" do
    it "appends a JobLog with auto-incremented sequence" do
      handler.log("hello")
      handler.log("world")
      expect(run.job_logs.order(:sequence).pluck(:chunk)).to eq(%w[ hello world ])
    end

    it "skips blank chunks (would otherwise hit JobLog presence validation)" do
      expect { handler.log("") }.not_to change { run.job_logs.count }
      expect { handler.log("   \n\n  ") }.not_to change { run.job_logs.count }
    end

    it "still bumps the heartbeat on blank chunks (sign of life from upstream stream)" do
      run.update_columns(last_heartbeat_at: 1.hour.ago)
      handler.log("")
      expect(run.reload.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe "#cancel_downstream!" do
    let!(:s1) { Step.create!(workflow: workflow, kind: "auto_rebase",  position: 0) }
    let!(:s2) { Step.create!(workflow: workflow, kind: "agent_rebase", position: 1) }
    let!(:s3) { Step.create!(workflow: workflow, kind: "force_push",   position: 2) }
    before do
      s1.update!(next_step_id: s2.id)
      s2.update!(next_step_id: s3.id)
    end

    let(:cancel_run) do
      r = Run.create!(job: job, step: s1, trigger_kind: "rebase")
      r.start!; r.save!
      r
    end

    it "cancels every downstream step in the chain" do
      handler_class.new(cancel_run).send(:cancel_downstream!, reason: "auto-rebased clean")
      expect(s2.reload.state).to eq("cancelled")
      expect(s3.reload.state).to eq("cancelled")
    end

    it "leaves the current step alone (it's still mid-execution)" do
      s1.start!; s1.save!
      handler_class.new(cancel_run).send(:cancel_downstream!)
      expect(s1.reload.state).to eq("running")
    end

    it "is idempotent — already-terminal steps stay as they were" do
      s2.update!(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      handler_class.new(cancel_run).send(:cancel_downstream!)
      expect(s2.reload.state).to eq("succeeded")
      expect(s3.reload.state).to eq("cancelled")
    end

    it "logs each cancellation with the reason" do
      handler_class.new(cancel_run).send(:cancel_downstream!, reason: "nothing left to do")
      logs = cancel_run.job_logs.pluck(:chunk).join("\n")
      expect(logs).to include("cancelling downstream step ##{s2.id}")
      expect(logs).to include("nothing left to do")
    end
  end

  describe "#parent_session_id resolution" do
    let!(:upstream_step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
    let!(:current_step)  { Step.create!(workflow: workflow, kind: "summarize", position: 1) }
    before { upstream_step.update!(next_step_id: current_step.id) }

    it "is nil for the first step in a workflow" do
      run = Run.create!(job: job, step: upstream_step, trigger_kind: "initial")
      h = handler_class.new(run)
      expect(h.parent_session_id).to be_nil
    end

    it "is nil when upstream hasn't succeeded yet" do
      run = Run.create!(job: job, step: current_step, trigger_kind: "initial")
      h = handler_class.new(run)
      expect(h.parent_session_id).to be_nil
    end

    it "returns the upstream step's last successful run's session_id" do
      upstream_run = Run.create!(job: job, step: upstream_step, trigger_kind: "initial",
                                  state: "succeeded")
      ClaudeSession.create!(resumable: upstream_run, session_id: "S-upstream", transcript_jsonl: "x")
      upstream_step.update!(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      current_run = Run.create!(job: job, step: current_step, trigger_kind: "initial")
      h = handler_class.new(current_run)
      expect(h.parent_session_id).to eq("S-upstream")
    end

    it "resumes summarize from implement when a non-agentic grade step is between them" do
      grade_step = Step.create!(workflow: workflow, kind: "grade", position: 1)
      current_step.update!(position: 2)
      upstream_step.update!(next_step_id: grade_step.id)
      grade_step.update!(next_step_id: current_step.id)
      upstream_run = Run.create!(job: job, step: upstream_step, trigger_kind: "retry",
                                  state: "succeeded")
      ClaudeSession.create!(resumable: upstream_run, session_id: "S-implement", transcript_jsonl: "x")
      upstream_step.update!(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
      grade_step.update!(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      current_run = Run.create!(job: job, step: current_step, trigger_kind: "retry")
      h = handler_class.new(current_run)

      expect(h.parent_session_id).to eq("S-implement")
    end

    it "an explicit run.parent_session_id wins over the chain" do
      run = Run.create!(job: job, step: current_step, trigger_kind: "manual",
                        parent_session_id: "S-explicit")
      h = handler_class.new(run)
      expect(h.parent_session_id).to eq("S-explicit")
    end
  end

  describe "#agent_provider" do
    it "prefers the Run provider" do
      workflow.update!(agent_provider: "claude")
      run.update!(agent_provider: "codex")
      expect(handler.agent_provider).to eq("codex")
    end
  end

  describe "#agent_adapter" do
    it "builds the adapter for the resolved provider" do
      run.update!(agent_provider: "codex")
      expect(handler.agent_adapter).to be_a(AgentProviders::Codex)
    end
  end

  describe "#run_agent" do
    let(:fake_result) do
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: "done",
        session_id: nil
      )
    end

    it "prepends the live environment snapshot to the adapter prompt" do
      fake_adapter = instance_double(AgentProviders::Base)
      received_prompt = nil
      allow(handler).to receive(:agent_adapter).and_return(fake_adapter)
      allow(fake_adapter).to receive(:run) do |prompt:, **|
        received_prompt = prompt
        fake_result
      end
      allow(fake_adapter).to receive(:record_result!).and_return(fake_result)

      handler.send(:run_agent, prompt: "repair the aqueduct")

      expect(received_prompt).to start_with("Agent environment snapshot:")
      expect(received_prompt).to include("Repository: #{job.repository.slug}")
      expect(received_prompt).to include("Workflow: ##{workflow.id} trigger=initial")
      expect(received_prompt).to include("MCP/tools: run sidecar `syrus-mcp-sidecar`")
      expect(received_prompt).to include("repair the aqueduct")
    end
  end

  describe "#perform_agentic_change_step" do
    let(:fake_ws) { instance_double(WorkflowWorkspace, setup: nil, path: Rails.root) }

    before do
      allow(handler).to receive(:workspace).and_return(fake_ws)
      allow(handler).to receive(:run_agent)
      allow(handler).to receive(:commit_agent_changes)
      allow(handler).to receive(:assert_branch_history_intact!)
      allow(handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
      allow(handler).to receive(:head_sha).and_return("abc123")
    end

    it "runs the shared change lifecycle and records diff metadata" do
      expect(fake_ws).to receive(:setup)
      expect(handler).to receive(:run_agent).with(prompt: "shared prompt")
      expect(handler).to receive(:commit_agent_changes).with("shared commit message")
      expect(handler).to receive(:assert_branch_history_intact!)

      handler.perform_agentic_change_step(
        log_message: "invoking shared path",
        commit_message: "shared commit message"
      ) do
        run.update!(prompt: "shared prompt")
      end

      expect(run.reload.agent_diff).to eq("diff --git a/foo.rb b/foo.rb\n+bar")
      expect(run.head_sha).to eq("abc123")
      expect(run.job_logs.last.chunk).to eq("invoking shared path")
    end

    it "fails unchanged agent runs before recording diff metadata" do
      allow(handler).to receive(:diff_against_default).and_return("")

      expect {
        handler.perform_agentic_change_step(
          log_message: "invoking shared path",
          commit_message: "shared commit message"
        ) do
          run.update!(prompt: "shared prompt")
        end
      }.to raise_error(Steps::Base::StepFailed, "agent produced no changes")

      expect(run.reload.agent_diff).to be_nil
      expect(run.head_sha).to be_nil
    end
  end

  describe "#buffered_log_sink" do
    it "buffers small chunks below byte threshold without writing to DB" do
      sink, flush = handler.buffered_log_sink
      sink.call("hello ", kind: "assistant_text")
      sink.call("world",  kind: "assistant_text")
      expect(run.job_logs.count).to eq(0)
      flush.call
      expect(run.job_logs.count).to eq(1)
      expect(run.job_logs.first.chunk).to eq("hello world")
    end

    # Regression: ClaudeInvocation passes structured tool metadata
    # (tool_name, tool_input on tool_use events; tool_result_content,
    # tool_use_id on tool_result events) as kwargs to log_sink. The
    # sink only uses chunk + kind but must tolerate the extras
    # without ArgumentError. Production hit "ArgumentError: unknown
    # keywords: :tool_name, :tool_input" mid-run on the first
    # submit_summary MCP call.
    it "tolerates the structured tool-metadata kwargs ClaudeInvocation passes on tool_use/tool_result" do
      sink, _flush = handler.buffered_log_sink

      expect {
        sink.call("● Bash(ls)", kind: "tool_call", tool_name: "Bash", tool_input: { "command" => "ls" })
      }.not_to raise_error

      expect {
        sink.call("  ⎿ ok", kind: "tool_result", tool_result_content: "ok",
                            tool_result_error: false, tool_use_id: "abc")
      }.not_to raise_error
    end

    it "waits for LOG_FLUSH_MIN_GAP before flushing byte-threshold bursts" do
      now = Time.zone.local(2026, 5, 11, 12, 0, 0)
      allow(Time).to receive(:current) { now }
      sink, _flush = handler.buffered_log_sink
      sink.call("x" * (Steps::Base::LOG_FLUSH_BYTES + 1), kind: "assistant_text")
      expect(run.job_logs.count).to eq(0)

      now += Steps::Base::LOG_FLUSH_MIN_GAP + 0.01
      sink.call("y", kind: "assistant_text")

      expect(run.job_logs.count).to eq(1)
      expect(run.job_logs.first.chunk).to eq(("x" * (Steps::Base::LOG_FLUSH_BYTES + 1)) + "y")
    end

    it "limits a 640 KB burst to one drain flush when it ends inside the minimum gap" do
      now = Time.zone.local(2026, 5, 11, 12, 0, 0)
      allow(Time).to receive(:current) { now }
      sink, flush = handler.buffered_log_sink

      40.times do |i|
        sink.call(i.to_s.rjust(4, "0") + ("x" * (16 * 1024 - 4)), kind: "assistant_text")
        now += 0.0025
      end

      expect(run.job_logs.count).to eq(0)

      flush.call

      logs = run.job_logs.order(:sequence)
      expect(logs.count).to eq(1)
      expect(logs.first.chunk.bytesize).to be > 600.kilobytes
      expect(logs.first.chunk).to start_with("0000")
      expect(logs.first.chunk).to include("0039")
    end

    it "flushes at most five times per second for sustained byte-threshold output" do
      now = Time.zone.local(2026, 5, 11, 12, 0, 0)
      allow(Time).to receive(:current) { now }
      sink, flush = handler.buffered_log_sink

      100.times do |i|
        sink.call(i.to_s.rjust(4, "0") + ("x" * (16 * 1024 - 4)), kind: "assistant_text")
        now += 0.01
      end
      flush.call

      logs = run.job_logs.order(:sequence).pluck(:chunk)
      expect(logs.count).to be <= 6 # five rate-limited flushes plus final drain
      expect(logs.join).to start_with("0000")
      expect(logs.join).to include("0099")
    end

    it "flushes immediately at LOG_FLUSH_MAX_BUF even inside the minimum gap" do
      now = Time.zone.local(2026, 5, 11, 12, 0, 0)
      allow(Time).to receive(:current) { now }
      sink, _flush = handler.buffered_log_sink

      sink.call("x" * (Steps::Base::LOG_FLUSH_MAX_BUF + 1), kind: "assistant_text")

      expect(run.job_logs.count).to eq(1)
      expect(run.job_logs.first.chunk.bytesize).to eq(Steps::Base::LOG_FLUSH_MAX_BUF + 1)
    end

    it "flushes when LOG_FLUSH_INTERVAL has elapsed since last flush" do
      # freeze_time so last_flush has usec: 0; travel() stubs via
      # .change(usec: 0) and would give elapsed < 1s if last_flush
      # has sub-second precision captured from the real clock.
      freeze_time
      sink, flush = handler.buffered_log_sink
      sink.call("line one", kind: "assistant_text")
      expect(run.job_logs.count).to eq(0)

      travel(Steps::Base::LOG_FLUSH_INTERVAL + 0.1)
      sink.call("line two", kind: "assistant_text")

      # Interval elapsed on the second call — both lines land in one row
      expect(run.job_logs.count).to eq(1)
      expect(run.job_logs.first.chunk).to include("line one")
    end

    it "flushes on kind change to keep different-kind chunks in separate rows" do
      sink, flush = handler.buffered_log_sink
      sink.call("agent text", kind: "assistant_text")
      sink.call("tool call",  kind: "tool_call")

      logs = run.job_logs.order(:sequence)
      expect(logs.count).to eq(1)
      expect(logs.first.chunk).to eq("agent text")
      expect(logs.first.kind).to eq("assistant_text")

      flush.call
      expect(run.job_logs.count).to eq(2)
      expect(run.job_logs.order(:sequence).last.chunk).to eq("tool call")
      expect(run.job_logs.order(:sequence).last.kind).to eq("tool_call")
    end

    it "drain flush writes any trailing partial buffer" do
      sink, flush = handler.buffered_log_sink
      sink.call("partial", kind: "system")
      expect(run.job_logs.count).to eq(0)
      flush.call
      expect(run.job_logs.first.chunk).to eq("partial")
      expect(run.job_logs.first.kind).to eq("system")
    end

    it "calling flush twice does not double-write" do
      sink, flush = handler.buffered_log_sink
      sink.call("data", kind: "assistant_text")
      flush.call
      flush.call
      expect(run.job_logs.count).to eq(1)
    end

    it "does not accumulate blank or whitespace-only chunks (mirrors #log contract)" do
      sink, flush = handler.buffered_log_sink
      sink.call("real", kind: "assistant_text")
      sink.call("",        kind: "assistant_text")
      sink.call("   \n\n", kind: "assistant_text")
      flush.call
      expect(run.job_logs.count).to eq(1)
      expect(run.job_logs.first.chunk).to eq("real")
    end
  end

  describe "#assert_branch_history_intact!" do
    # Build a workspace that mirrors the stacked-PR clone shape: a
    # working tree with origin/<default_branch> as the only ref to
    # the upstream, and the agent branch checked out off a sibling
    # branch (no local <default_branch> ref at all). This is what
    # WorkflowWorkspace produces when `effective_base_branch` resolves
    # to a stack parent rather than master — and what
    # `git merge-base master HEAD` choked on in production.
    let(:workspace_dir) { Pathname.new(Dir.mktmpdir("syrus-history-check")) }
    let(:bare_remote) { Pathname.new(Dir.mktmpdir("syrus-history-bare")) }
    let(:fake_ws) { instance_double(WorkflowWorkspace, path: workspace_dir) }

    before do
      # Seed a bare remote with one commit on master.
      system("git", "-C", bare_remote.to_s, "init", "--bare", "--initial-branch=master",
             out: File::NULL, err: File::NULL)
      seed = Pathname.new(Dir.mktmpdir("syrus-history-seed"))
      system("git", "-C", seed.to_s, "init", "--initial-branch=master", out: File::NULL, err: File::NULL)
      system("git", "-C", seed.to_s, "config", "user.email", "x@x.test")
      system("git", "-C", seed.to_s, "config", "user.name", "Test")
      File.write(seed.join("README.md"), "seed\n")
      system("git", "-C", seed.to_s, "add", "README.md", out: File::NULL, err: File::NULL)
      system("git", "-C", seed.to_s, "commit", "-m", "seed", out: File::NULL, err: File::NULL)
      system("git", "-C", seed.to_s, "remote", "add", "origin", bare_remote.to_s, out: File::NULL, err: File::NULL)
      system("git", "-C", seed.to_s, "push", "-u", "origin", "master", out: File::NULL, err: File::NULL)

      # Push a sibling "stack parent" branch — what an upstream Job
      # would have left on origin.
      File.write(seed.join("parent.rb"), "parent\n")
      system("git", "-C", seed.to_s, "add", "parent.rb", out: File::NULL, err: File::NULL)
      system("git", "-C", seed.to_s, "commit", "-m", "stack parent", out: File::NULL, err: File::NULL)
      system("git", "-C", seed.to_s, "branch", "syrus/issue-198-431", out: File::NULL, err: File::NULL)
      system("git", "-C", seed.to_s, "push", "origin", "syrus/issue-198-431", out: File::NULL, err: File::NULL)
      FileUtils.rm_rf(seed)

      # Clone with --branch on the stack-parent. This produces a
      # local repo with refs/heads/syrus/issue-198-431 + a
      # refs/remotes/origin/master remote-tracking ref, but NO
      # local refs/heads/master. Exactly the production shape.
      FileUtils.rm_rf(workspace_dir)
      system("git", "clone", "--branch", "syrus/issue-198-431",
             bare_remote.to_s, workspace_dir.to_s, out: File::NULL, err: File::NULL)
      system("git", "-C", workspace_dir.to_s, "config", "user.email", "x@x.test")
      system("git", "-C", workspace_dir.to_s, "config", "user.name", "Test")
      system("git", "-C", workspace_dir.to_s, "checkout", "-b", "syrus/issue-199-430",
             out: File::NULL, err: File::NULL)
      File.write(workspace_dir.join("feature.rb"), "feature\n")
      system("git", "-C", workspace_dir.to_s, "add", "feature.rb", out: File::NULL, err: File::NULL)
      system("git", "-C", workspace_dir.to_s, "commit", "-m", "agent change",
             out: File::NULL, err: File::NULL)

      job.repository.update!(default_branch: "master")
      allow(handler).to receive(:workspace).and_return(fake_ws)
    end

    after do
      FileUtils.rm_rf(workspace_dir)
      FileUtils.rm_rf(bare_remote)
    end

    it "passes on a stacked-PR clone with no local master ref (Job 430 shape — was a false positive)" do
      # Sanity: confirm the workspace really has no local master ref.
      out = `git -C #{workspace_dir} branch --list master`.strip
      expect(out).to eq(""), "expected no local master ref, got: #{out.inspect}"

      expect { handler.send(:assert_branch_history_intact!) }.not_to raise_error
      expect(run.reload.agent_outcome).not_to eq("git_state_corrupt")
    end

    it "captures the agent diff on a stacked-PR clone with no local master ref (Job 442 shape)" do
      # Sanity: confirm the workspace really has no local master ref.
      out = `git -C #{workspace_dir} branch --list master`.strip
      expect(out).to eq(""), "expected no local master ref, got: #{out.inspect}"

      diff = handler.send(:diff_against_default)

      expect(diff).to include("feature.rb")
    end

    it "still raises AgentBrokeGitState on a genuine orphan branch" do
      system("git", "-C", workspace_dir.to_s, "checkout", "--orphan", "orphan-branch",
             out: File::NULL, err: File::NULL)
      File.write(workspace_dir.join("only.rb"), "only\n")
      system("git", "-C", workspace_dir.to_s, "add", "only.rb", out: File::NULL, err: File::NULL)
      system("git", "-C", workspace_dir.to_s, "commit", "-m", "orphan", out: File::NULL, err: File::NULL)

      expect { handler.send(:assert_branch_history_intact!) }
        .to raise_error(Steps::Base::AgentBrokeGitState, /no common ancestor with origin\/master/)
      expect(run.reload.agent_outcome).to eq("git_state_corrupt")
    end
  end
end
