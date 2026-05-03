require "rails_helper"

RSpec.describe ReapStaleRunsJob do
  let(:job) { Factories.job }

  def stale_run(trigger_kind: "initial", heartbeat_age: 10.minutes)
    run = Run.create!(job: job, trigger_kind: trigger_kind)
    run.update_columns(
      state: "running",
      started_at: heartbeat_age.ago,
      last_heartbeat_at: heartbeat_age.ago
    )
    run
  end

  describe "#perform" do
    it "marks a stale running run as failed" do
      run = stale_run
      described_class.perform_now
      expect(run.reload.state).to eq("failed")
    end

    it "sets agent_outcome to worker_died" do
      run = stale_run
      described_class.perform_now
      expect(run.reload.agent_outcome).to eq("worker_died")
    end

    it "sets finished_at" do
      run = stale_run
      freeze_time do
        described_class.perform_now
        expect(run.reload.finished_at).to eq(Time.current)
      end
    end

    it "leaves a freshly-heartbeated running run alone" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "running", started_at: 5.minutes.ago, last_heartbeat_at: 30.seconds.ago)
      described_class.perform_now
      expect(run.reload.state).to eq("running")
    end

    it "ignores non-running runs even if their timestamps are old" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "succeeded", started_at: 10.minutes.ago, finished_at: 8.minutes.ago)
      described_class.perform_now
      expect(run.reload.state).to eq("succeeded")
    end

    it "handles worktree cleanup errors without aborting the job" do
      run = stale_run
      allow_any_instance_of(JobWorkspace).to receive(:cleanup).and_raise(RuntimeError, "no such worktree")
      expect { described_class.perform_now }.not_to raise_error
      expect(run.reload.state).to eq("failed")
    end

    it "reaps all stale runs in one pass" do
      r1 = stale_run(trigger_kind: "initial")
      r2 = Run.create!(job: Factories.job, trigger_kind: "pr_comment")
      r2.update_columns(state: "running", started_at: 20.minutes.ago, last_heartbeat_at: 20.minutes.ago)

      described_class.perform_now

      expect(r1.reload.state).to eq("failed")
      expect(r2.reload.state).to eq("failed")
    end
  end

  describe "Run.stale scope" do
    it "includes a running run whose last_heartbeat_at is past the threshold" do
      run = stale_run
      expect(Run.stale).to include(run)
    end

    it "includes a running run with no heartbeat but an old started_at" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "running", started_at: 10.minutes.ago, last_heartbeat_at: nil)
      expect(Run.stale).to include(run)
    end

    it "excludes a running run with a recent heartbeat" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "running", started_at: 5.minutes.ago, last_heartbeat_at: 30.seconds.ago)
      expect(Run.stale).not_to include(run)
    end

    it "excludes a non-running run regardless of timestamps" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 8.minutes.ago)
      expect(Run.stale).not_to include(run)
    end
  end
end
