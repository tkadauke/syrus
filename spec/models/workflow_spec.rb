require "rails_helper"

RSpec.describe Workflow do
  let(:job) { Factories.job }

  def build_wf(**overrides)
    described_class.new({ job: job, trigger_kind: "initial" }.merge(overrides))
  end

  describe "validations" do
    it "is valid with a known trigger_kind" do
      expect(build_wf(trigger_kind: "initial")).to be_valid
    end

    it "rejects unknown trigger_kind" do
      expect(build_wf(trigger_kind: "rumour")).not_to be_valid
    end

    it "rejects unknown agent_provider" do
      expect(build_wf(agent_provider: "oracle")).not_to be_valid
    end

    it "requires a job" do
      expect(build_wf(job: nil)).not_to be_valid
    end
  end

  describe "AASM state machine" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "starts queued" do
      expect(wf.state).to eq("queued")
    end

    it "transitions queued → running with started_at" do
      freeze_time do
        wf.start!
        wf.save!
        expect(wf).to be_running
        expect(wf.started_at).to eq(Time.current)
      end
    end

    it "transitions running → succeeded with finished_at" do
      wf.start!
      freeze_time do
        wf.succeed!
        wf.save!
        expect(wf).to be_succeeded
        expect(wf.finished_at).to eq(Time.current)
      end
    end

    it "transitions running → failed with finished_at" do
      wf.start!
      wf.fail!
      wf.save!
      expect(wf).to be_failed
      expect(wf.finished_at).to be_present
    end
  end

  describe "feedback addressed watermark" do
    it "records the newest feedback comment time when a pr_comment workflow succeeds" do
      older = Time.parse("2026-05-02 05:00:00 UTC")
      newer = Time.parse("2026-05-02 05:05:00 UTC")
      wf = described_class.create!(
        job: job,
        trigger_kind: "pr_comment",
        artifacts: {
          "pr_comments" => [
            { "body" => "first", "created_at" => older.iso8601 },
            { "body" => "second", "created_at" => newer.iso8601 }
          ]
        }
      )

      wf.start!
      wf.succeed!
      wf.save!

      expect(job.reload.last_feedback_addressed_at.utc).to be_within(1.second).of(newer)
    end

    it "does not move the addressed watermark for failed pr_comment workflows" do
      wf = described_class.create!(
        job: job,
        trigger_kind: "pr_comment",
        artifacts: {
          "pr_comments" => [
            { "body" => "still broken", "created_at" => Time.parse("2026-05-02 05:00:00 UTC").iso8601 }
          ]
        }
      )

      wf.start!
      wf.fail!
      wf.save!

      expect(job.reload.last_feedback_addressed_at).to be_nil
    end
  end

  describe "#cancel cascades to active descendants" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "ci_failure") }

    it "cancels every still-queued Step and any active Runs on them" do
      done_step    = Step.create!(workflow: wf, kind: "prepare",         position: 0, state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      stuck_step_1 = Step.create!(workflow: wf, kind: "summarize_amend", position: 1)  # queued
      stuck_step_2 = Step.create!(workflow: wf, kind: "push",            position: 2)  # queued

      done_run     = Run.create!(job: job, step: done_step, trigger_kind: "ci_failure", state: "succeeded")
      stuck_run    = Run.create!(job: job, step: stuck_step_1, trigger_kind: "ci_failure")  # queued

      wf.start!
      wf.cancel!
      wf.save!

      expect(wf).to be_cancelled
      expect(stuck_step_1.reload.state).to eq("cancelled")
      expect(stuck_step_2.reload.state).to eq("cancelled")
      expect(stuck_run.reload.state).to    eq("cancelled")

      # Already-terminal records are left alone.
      expect(done_step.reload.state).to eq("succeeded")
      expect(done_run.reload.state).to  eq("succeeded")
    end

    it "is idempotent — cancelling again does not crash on already-cancelled descendants" do
      step = Step.create!(workflow: wf, kind: "summarize_amend", position: 0, state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      wf.start!
      wf.cancel!
      wf.save!
      expect(step.reload.state).to eq("cancelled")
    end
  end

  describe "artifacts" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "round-trips JSON-serialized values" do
      wf.set_artifact!("pr_title", "Add greeting helper")
      wf.set_artifact!("pr_body", "Adds a tiny greet helper.")
      reloaded = described_class.find(wf.id)
      expect(reloaded.artifact("pr_title")).to eq("Add greeting helper")
      expect(reloaded.artifact("pr_body")).to eq("Adds a tiny greet helper.")
    end

    it "is nil-safe for unset keys" do
      expect(wf.artifact("never_set")).to be_nil
    end

    it "preserves prior keys when setting a new one (merge, not replace)" do
      wf.set_artifact!("a", 1)
      wf.set_artifact!("b", 2)
      expect(wf.reload.artifacts).to eq("a" => 1, "b" => 2)
    end

    it "supports rich values (hashes, arrays — JSON serializes anything)" do
      wf.set_artifact!("test_plan", { steps: [ "rspec", "lint" ], note: "ok" })
      reloaded = described_class.find(wf.id)
      expect(reloaded.artifact("test_plan")).to eq("steps" => [ "rspec", "lint" ], "note" => "ok")
    end
  end

  describe "#current_iteration" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "returns nil when the workflow has no loop steps" do
      Step.create!(workflow: wf, kind: "implement", position: 0)

      expect(wf.current_iteration).to be_nil
    end

    it "returns the highest iteration across active loop instances" do
      Step.create!(workflow: wf, kind: "implement", position: 0, loop_id: "loop-a", iteration: 2, state: "queued")
      Step.create!(workflow: wf, kind: "summarize", position: 1, loop_id: "loop-b", iteration: 3, state: "running")
      Step.create!(workflow: wf, kind: "pr_open", position: 2, loop_id: "loop-a", iteration: 1, state: "queued")

      expect(wf.current_iteration).to eq(3)
    end

    it "ignores completed loop steps" do
      Step.create!(workflow: wf, kind: "implement", position: 0, loop_id: "loop-a", iteration: 4, state: "succeeded")
      Step.create!(workflow: wf, kind: "summarize", position: 1, loop_id: "loop-a", iteration: 2, state: "running")

      expect(wf.current_iteration).to eq(2)
    end

    it "returns nil when all loop steps are completed" do
      Step.create!(workflow: wf, kind: "implement", position: 0, loop_id: "loop-a", iteration: 1, state: "succeeded")
      Step.create!(workflow: wf, kind: "summarize", position: 1, loop_id: "loop-a", iteration: 2, state: "failed")

      expect(wf.current_iteration).to be_nil
    end
  end

  describe "#record_run_failure!" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial").tap(&:start!).tap(&:save!) }

    it "increments failure_count" do
      expect { wf.record_run_failure! }.to change { wf.reload.failure_count }.by(1)
    end

    it "auto-fails the Workflow when count crosses AppSetting.max_job_failures" do
      cap = AppSetting.max_job_failures
      cap.times { wf.record_run_failure! }
      expect(wf.reload).to be_failed
    end

    it "does not affect other workflows on the same Job (per-Workflow scope)" do
      other_wf = described_class.create!(job: job, trigger_kind: "pr_comment")
      cap = AppSetting.max_job_failures
      cap.times { wf.record_run_failure! }
      expect(other_wf.reload.state).to eq("queued")
      expect(other_wf.failure_count).to eq(0)
    end
  end
end
