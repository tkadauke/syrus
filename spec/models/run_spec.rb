require "rails_helper"

RSpec.describe Run do
  let(:job) { Factories.job }

  describe "AASM state machine (was Job's)" do
    it "starts queued" do
      expect(job.initial_run).to be_queued
    end

    it "queued → running via start, sets started_at" do
      run = job.initial_run
      freeze_time do
        run.start!
        expect(run.state).to eq("running")
        expect(run.started_at).to eq(Time.current)
      end
    end

    it "running → succeeded via succeed, sets finished_at" do
      run = job.initial_run
      run.start!
      freeze_time do
        run.succeed!
        expect(run.state).to eq("succeeded")
        expect(run.finished_at).to eq(Time.current)
      end
    end

    it "queued → cancelled via cancel" do
      run = job.initial_run
      expect { run.cancel! }.to change(run, :state).from("queued").to("cancelled")
      expect(run.finished_at).to be_present
    end

    it "running → failed via fail" do
      run = job.initial_run
      run.start!
      expect { run.fail! }.to change(run, :state).from("running").to("failed")
    end

    it "queued → failed via fail (pre-flight failure)" do
      run = job.initial_run
      expect { run.fail! }.to change(run, :state).from("queued").to("failed")
    end

    it "cannot succeed without starting" do
      run = job.initial_run
      expect(run.may_succeed?).to be false
    end

    it "cannot cancel a terminal run" do
      run = job.initial_run
      run.start!; run.succeed!
      expect(run.may_cancel?).to be false
    end
  end

  describe "trigger_kind" do
    it "validates inclusion" do
      run = Run.new(job: job, trigger_kind: "weird")
      expect(run).not_to be_valid
    end

    it "exposes #initial?" do
      expect(job.initial_run).to be_initial
    end

    it "is not initial for other triggers" do
      followup = Run.create!(job: job, trigger_kind: "pr_comment")
      expect(followup).not_to be_initial
    end

    it "accepts 'rebase' as a valid trigger" do
      r = Run.new(job: job, trigger_kind: "rebase")
      expect(r).to be_valid
    end

    it "validates agent_provider" do
      r = Run.new(job: job, trigger_kind: "initial", agent_provider: "oracle")
      expect(r).not_to be_valid
      expect(r.errors[:agent_provider]).to be_present
    end

    it "exposes #rebase?" do
      r = Run.create!(job: job, trigger_kind: "rebase")
      expect(r).to be_rebase
      expect(job.initial_run).not_to be_rebase
    end
  end

  describe "scopes" do
    it "active = queued + running" do
      a = job.initial_run
      Run.create!(job: job, trigger_kind: "pr_comment")  # queued
      a.start!; a.save!
      expect(job.runs.active.count).to eq(2)
    end

    it "terminal = succeeded + failed + cancelled" do
      a = job.initial_run
      a.start!; a.succeed!; a.save!
      Run.create!(job: job, trigger_kind: "pr_comment")  # queued, not terminal
      expect(job.runs.terminal.count).to eq(1)
    end
  end

  describe ".average_duration_for" do
    it "returns nil when no completed runs of that trigger kind exist" do
      Factories.job  # one queued initial run, not terminal
      expect(Run.average_duration_for("initial")).to be_nil
    end

    it "averages finished_at - started_at across terminal runs of the trigger kind" do
      r1 = Factories.run  # initial
      r1.update_columns(state: "succeeded", started_at: 100.seconds.ago, finished_at: 70.seconds.ago)  # 30s
      r2 = Factories.run
      r2.update_columns(state: "succeeded", started_at: 50.seconds.ago, finished_at: 0.seconds.ago)   # 50s
      Factories.run.update_columns(state: "queued")  # not terminal — ignored
      expect(Run.average_duration_for("initial")).to eq(40)
    end

    it "scopes by trigger_kind — pr_comment runs don't count toward initial average" do
      initial_run = Factories.run
      initial_run.update_columns(state: "succeeded", started_at: 100.seconds.ago, finished_at: 90.seconds.ago)  # 10s
      followup_job = Factories.job
      followup = Run.create!(job: followup_job, trigger_kind: "pr_comment")
      followup.update_columns(state: "succeeded", started_at: 100.seconds.ago, finished_at: 0.seconds.ago)  # 100s
      expect(Run.average_duration_for("initial")).to eq(10)
      expect(Run.average_duration_for("pr_comment")).to eq(100)
    end

    # Production 500 reproducer (2026-05-04): a terminal Run with
    # started_at set but finished_at nil (e.g. crash path that didn't
    # transition cleanly) used to slip through `where.not(a: nil, b: nil)`
    # — that compiles to `NOT (a IS NULL AND b IS NULL)`, only excluding
    # rows where BOTH are nil. The block then did `nil - Time` and the
    # whole jobs/show page 500'd.
    it "ignores terminal runs with finished_at unset (crash recovery survivor)" do
      ok = Factories.run
      ok.update_columns(state: "succeeded", started_at: 100.seconds.ago, finished_at: 70.seconds.ago)  # 30s
      crashed = Factories.run
      crashed.update_columns(state: "failed", started_at: 200.seconds.ago, finished_at: nil)
      expect { Run.average_duration_for("initial") }.not_to raise_error
      expect(Run.average_duration_for("initial")).to eq(30)
    end

    it "ignores terminal runs with started_at unset" do
      ok = Factories.run
      ok.update_columns(state: "succeeded", started_at: 100.seconds.ago, finished_at: 60.seconds.ago)  # 40s
      weird = Factories.run
      weird.update_columns(state: "failed", started_at: nil, finished_at: 1.second.ago)
      expect { Run.average_duration_for("initial") }.not_to raise_error
      expect(Run.average_duration_for("initial")).to eq(40)
    end
  end

  describe "auto-enqueue RunJob on commit" do
    it "enqueues a RunJob with the new Run's id" do
      job  # force creation outside the expect block so its initial-Run
      # enqueue isn't counted against this assertion
      expect {
        Run.create!(job: job, trigger_kind: "pr_comment")
      }.to have_enqueued_job(RunJob).with { |id| expect(id).to be_a(Integer) }
    end

    it "does not enqueue if the Run is created in a terminal state" do
      job
      expect {
        Run.create!(job: job, trigger_kind: "manual", state: "succeeded")
      }.not_to have_enqueued_job(RunJob)
    end

    it "enqueues with the job's SolidQueue priority for a high-priority job" do
      high_job = Factories.job(priority: "high")
      expected_priority = Job::PRIORITY_TO_SQ["high"]
      Run.create!(job: high_job, trigger_kind: "pr_comment")
      run_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == RunJob }
      expect(run_jobs.last[:priority]).to eq(expected_priority)
    end

    it "enqueues with medium SolidQueue priority by default" do
      job
      Run.create!(job: job, trigger_kind: "pr_comment")
      run_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == RunJob }
      expect(run_jobs.last[:priority]).to eq(Job::PRIORITY_TO_SQ["medium"])
    end
  end

  describe "transcript pruning on success" do
    it "clears ClaudeSession transcript_jsonl when the Run transitions to succeeded" do
      run = job.initial_run
      run.start!; run.save!
      session = ClaudeSession.create!(run: run, session_id: "abc", transcript_jsonl: "big payload")
      run.succeed!; run.save!
      expect(session.reload.transcript_jsonl).to be_nil
    end

    it "does not clear transcript when the Run fails" do
      run = job.initial_run
      run.start!; run.save!
      session = ClaudeSession.create!(run: run, session_id: "abc", transcript_jsonl: "big payload")
      run.fail!; run.save!
      expect(session.reload.transcript_jsonl).to eq("big payload")
    end

    it "is a no-op when the Run has no ClaudeSession" do
      run = job.initial_run
      run.start!; run.save!
      expect { run.succeed!; run.save! }.not_to raise_error
    end
  end

  describe "#terminal?" do
    it "is false for queued and running" do
      run = job.initial_run
      expect(run).not_to be_terminal
      run.start!
      expect(run).not_to be_terminal
    end

    it "is true for succeeded, failed, cancelled" do
      [ ->(r) { r.start!; r.succeed! }, ->(r) { r.fail! }, ->(r) { r.cancel! } ].each do |drive|
        run = Run.create!(job: Factories.job, trigger_kind: "pr_comment")
        drive.call(run)
        expect(run).to be_terminal
      end
    end
  end
end
