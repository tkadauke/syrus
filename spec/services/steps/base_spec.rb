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
             :agent_adapter
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

    it "an explicit run.parent_session_id wins over the chain (Resume semantics)" do
      run = Run.create!(job: job, step: current_step, trigger_kind: "resume",
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
end
