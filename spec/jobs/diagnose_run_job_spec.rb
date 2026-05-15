require "rails_helper"

RSpec.describe DiagnoseRunJob do
  # Build a Run in `running` state with a given heartbeat age.
  def running_run(heartbeat_age: 30.seconds, agent_provider: "claude")
    run = Run.create!(job: Factories.job, trigger_kind: "initial")
    run.update_columns(
      state: "running",
      started_at: heartbeat_age.ago,
      last_heartbeat_at: heartbeat_age.ago,
      agent_provider: agent_provider
    )
    run
  end

  # SolidQueue tables aren't present in the test DB (single-database
  # setup). Stub the private helper that hits them so specs can drive
  # the SQ signal branch without needing the tables.
  def stub_sq_state(job_instance, sq_state, error: nil)
    allow(job_instance).to receive(:capture_sq_signals) do |snapshot, _run|
      snapshot.sq_job_state = sq_state
      if error && sq_state == "failed"
        snapshot.sq_error_class   = error[:class]
        snapshot.sq_error_message = error[:message]
      end
    end
  end

  # Return a job instance we can configure before perform.
  def build_job
    described_class.new
  end

  describe "#perform" do
    context "healthy run — fresh heartbeat, worktree present, agent running" do
      it "captures a healthy snapshot" do
        run = running_run(heartbeat_age: 30.seconds)

        job = build_job
        stub_sq_state(job, "claimed")
        # Worktree doesn't exist in tests; let the process-signal capture degrade.
        expect { job.perform(run.id) }.to change { run.run_health_snapshots.count }.by(1)

        snapshot = run.run_health_snapshots.last
        expect(snapshot.run_state).to eq("running")
        expect(snapshot.sq_job_state).to eq("claimed")
        expect(snapshot.health_status).to be_in(%w[healthy warning])
      end

      it "sets heartbeat_age_seconds from last_heartbeat_at" do
        run = running_run(heartbeat_age: 2.minutes)

        job = build_job
        stub_sq_state(job, "claimed")
        freeze_time do
          job.perform(run.id)
        end

        snapshot = run.run_health_snapshots.last
        expect(snapshot.heartbeat_age_seconds).to be_within(5).of(2.minutes.to_i)
      end

      it "captures log_count and last_log_preview from JobLogs" do
        run = running_run
        run.job_logs.create!(sequence: 0, chunk: "Starting implementation...")
        run.job_logs.create!(sequence: 1, chunk: "Writing code.")

        job = build_job
        stub_sq_state(job, "claimed")
        job.perform(run.id)

        snapshot = run.run_health_snapshots.last
        expect(snapshot.log_count).to eq(2)
        expect(snapshot.last_log_preview).to eq("Writing code.")
      end
    end

    context "stale-heartbeat run" do
      it "produces a warning snapshot when heartbeat is 5–30 min stale" do
        run = running_run(heartbeat_age: 10.minutes)

        job = build_job
        stub_sq_state(job, "claimed")
        job.perform(run.id)

        snapshot = run.run_health_snapshots.last
        expect(snapshot.health_status).to eq("warning")
        expect(snapshot.hint).to include("stale")
      end

      it "produces a critical snapshot when heartbeat exceeds STALE_HEARTBEAT_THRESHOLD" do
        run = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)

        job = build_job
        stub_sq_state(job, "claimed")
        job.perform(run.id)

        snapshot = run.run_health_snapshots.last
        expect(snapshot.health_status).to eq("critical")
        expect(snapshot.hint).to include("reaper")
      end
    end

    context "SQ-failed run" do
      it "produces a critical snapshot and surfaces the error class" do
        run = running_run

        job = build_job
        stub_sq_state(job, "failed", error: { class: "RuntimeError", message: "oops" })
        job.perform(run.id)

        snapshot = run.run_health_snapshots.last
        expect(snapshot.health_status).to eq("critical")
        expect(snapshot.sq_job_state).to eq("failed")
        expect(snapshot.sq_error_class).to eq("RuntimeError")
        expect(snapshot.hint).to include("Retry")
      end
    end

    context "worktree absent" do
      it "marks worktree_exists false without crashing" do
        run = running_run

        job = build_job
        stub_sq_state(job, "claimed")
        # WorkflowWorkspace.path_for points to a path that won't exist in
        # test — so worktree_exists ends up false when a step/workflow exists,
        # or nil when there's no step (legacy run). Either is acceptable.
        expect { job.perform(run.id) }.not_to raise_error

        snapshot = run.run_health_snapshots.last
        expect(snapshot).to be_persisted
        # worktree_exists is false (step present but dir absent) or nil (no step).
        expect([ false, nil ]).to include(snapshot.worktree_exists)
      end

      it "marks health_status critical when worktree dir is gone but run has a workflow" do
        run = running_run

        job = build_job
        stub_sq_state(job, "claimed")

        # Simulate: step+workflow exist, worktree dir is absent.
        allow(job).to receive(:capture_process_signals) do |snapshot, _run|
          snapshot.worktree_exists = false
        end

        job.perform(run.id)

        snapshot = run.run_health_snapshots.last
        expect(snapshot.health_status).to eq("critical")
        expect(snapshot.hint).to include("Workspace")
      end
    end

    context "SolidQueue tables unreachable" do
      it "creates a snapshot without crashing when SQ tables are absent" do
        run = running_run

        job = build_job
        # Let the real capture_sq_signals run; it rescues StatementInvalid.
        expect { job.perform(run.id) }.not_to raise_error

        snapshot = run.run_health_snapshots.last
        expect(snapshot).to be_persisted
        # sq_job_state is nil when SQ tables are unreachable.
        expect(snapshot.sq_job_state).to be_nil
      end
    end

    it "stores multiple snapshots per run in order" do
      run = running_run

      job = build_job
      stub_sq_state(job, "claimed")
      job.perform(run.id)

      job2 = build_job
      stub_sq_state(job2, "claimed")
      job2.perform(run.id)

      expect(run.run_health_snapshots.count).to eq(2)
      expect(run.run_health_snapshots.ordered.first.created_at)
        .to be <= run.run_health_snapshots.ordered.last.created_at
    end

    it "is a no-op when the Run is not found" do
      expect { described_class.perform_now(999_999) }
        .not_to raise_error
      expect(RunHealthSnapshot.count).to eq(0)
    end
  end

  describe "process signals" do
    it "matches the expected process for a Codex run" do
      job = build_job
      workspace_path = "/tmp/syrus-workspace"

      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/proc").and_return(true)
      allow(Dir).to receive(:glob).with("/proc/[0-9]*/cwd").and_return([
        "/proc/111/cwd",
        "/proc/222/cwd"
      ])
      allow(File).to receive(:readlink).and_call_original
      allow(File).to receive(:readlink).with("/proc/111/cwd").and_return(workspace_path)
      allow(File).to receive(:readlink).with("/proc/111/exe").and_return("/usr/bin/claude")
      allow(File).to receive(:readlink).with("/proc/222/cwd").and_return(workspace_path)
      allow(File).to receive(:readlink).with("/proc/222/exe").and_return("/usr/local/bin/codex")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/111/cmdline").and_return("claude\0--print")
      allow(File).to receive(:read).with("/proc/222/cmdline").and_return("codex\0exec")

      running, info = job.send(:check_agent_process, workspace_path, "codex")

      expect(running).to be(true)
      expect(info).to include("PID 222: codex exec")
      expect(info).not_to include("claude")
    end

    it "does not treat a Claude process as healthy for a Codex run" do
      job = build_job
      workspace_path = "/tmp/syrus-workspace"

      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/proc").and_return(true)
      allow(Dir).to receive(:glob).with("/proc/[0-9]*/cwd").and_return([ "/proc/111/cwd" ])
      allow(File).to receive(:readlink).and_call_original
      allow(File).to receive(:readlink).with("/proc/111/cwd").and_return(workspace_path)
      allow(File).to receive(:readlink).with("/proc/111/exe").and_return("/usr/bin/claude")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/111/cmdline").and_return("claude\0--print")

      running, info = job.send(:check_agent_process, workspace_path, "codex")

      expect(running).to be(false)
      expect(info).to be_nil
    end
  end

  describe "health status logic" do
    def snapshot_with(agent_provider: "claude", **attrs)
      run = running_run(agent_provider: agent_provider)
      s = RunHealthSnapshot.new(run: run, run_state: "running", **attrs)

      job = build_job
      [ job.send(:compute_health_status, s, run), job.send(:compute_hint, s, run) ]
    end

    it "is healthy when heartbeat is fresh and SQ claimed" do
      status, _hint = snapshot_with(heartbeat_age_seconds: 60, sq_job_state: "claimed",
                                    worktree_exists: true, claude_process_running: true)
      expect(status).to eq("healthy")
    end

    it "is warning when heartbeat is 10 min stale" do
      status, hint = snapshot_with(heartbeat_age_seconds: 10.minutes.to_i, sq_job_state: "claimed",
                                   worktree_exists: true, claude_process_running: true)
      expect(status).to eq("warning")
      expect(hint).to include("stale")
    end

    it "is critical when SQ job is failed" do
      status, hint = snapshot_with(sq_job_state: "failed", sq_error_class: "Errno::ENOENT",
                                   heartbeat_age_seconds: 60)
      expect(status).to eq("critical")
      expect(hint).to include("Retry")
    end

    it "is critical when worktree is gone" do
      status, hint = snapshot_with(worktree_exists: false, sq_job_state: "claimed",
                                   heartbeat_age_seconds: 60)
      expect(status).to eq("critical")
      expect(hint).to include("Workspace")
    end

    it "is critical when heartbeat exceeds 30 min threshold" do
      status, _hint = snapshot_with(heartbeat_age_seconds: (Run::STALE_HEARTBEAT_THRESHOLD + 1.minute).to_i,
                                    sq_job_state: "claimed")
      expect(status).to eq("critical")
    end

    it "is warning when SQ state is missing" do
      status, hint = snapshot_with(heartbeat_age_seconds: 60, sq_job_state: "missing")
      expect(status).to eq("warning")
      expect(hint).to include("SolidQueue job not found")
    end

    it "uses generic agent wording for a stale Codex run without a matching process" do
      status, hint = snapshot_with(agent_provider: "codex",
                                   heartbeat_age_seconds: 10.minutes.to_i,
                                   sq_job_state: "claimed",
                                   worktree_exists: true,
                                   claude_process_running: false)

      expect(status).to eq("critical")
      expect(hint).to include("agent process not found")
      expect(hint).not_to match(/claude/i)
    end

    it "uses generic agent wording for a healthy Codex run" do
      status, hint = snapshot_with(agent_provider: "codex",
                                   heartbeat_age_seconds: 60,
                                   sq_job_state: "claimed",
                                   worktree_exists: true,
                                   claude_process_running: true)

      expect(status).to eq("healthy")
      expect(hint).to include("agent active")
      expect(hint).not_to match(/claude/i)
    end
  end
end
