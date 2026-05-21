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

describe "Job state propagation (Phase 2)" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }

    it "drives :queued → :running on workflow.start! for non-auto_merge workflows" do
      wf = described_class.create!(job: job, trigger_kind: "initial")

      expect { wf.start!; wf.save! }
        .to change { job.reload.state }.from("queued").to("running")
    end

    it "drives :implemented → :running on workflow.start! for follow-up (pr_comment) workflows" do
      job.update!(state: "implemented")
      wf = described_class.create!(job: job, trigger_kind: "pr_comment")

      expect { wf.start!; wf.save! }
        .to change { job.reload.state }.from("implemented").to("running")
    end

    it "leaves Job state untouched on workflow.start! for auto_merge workflows" do
      job.update!(state: "approved")
      job.start_landing!; job.save!
      wf = described_class.create!(job: job, trigger_kind: "auto_merge")

      expect { wf.start!; wf.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("landing")
    end

    it "drives :running → :failed on workflow.fail! for non-auto_merge workflows" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)

      expect { wf.fail!; wf.save! }
        .to change { job.reload.state }.from("running").to("failed")
    end

    it "leaves Job state untouched on workflow.fail! for auto_merge workflows (fail_landing handles it)" do
      job.update!(state: "landing")
      wf = described_class.create!(job: job, trigger_kind: "auto_merge", state: "running", started_at: 1.minute.ago)

      expect { wf.fail!; wf.save! }
        .not_to change { job.reload.state }
    end

    it "drives :running → :implemented on workflow.succeed! for follow-up workflows whose chain doesn't include pr_open" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "pr_comment", state: "running", started_at: 1.minute.ago)

      expect { wf.succeed!; wf.save! }
        .to change { job.reload.state }.from("running").to("implemented")
    end

    it "does not transition Job on workflow.succeed! when Job has already moved past :running (auto-approval path)" do
      # Steps::PrOpen + AutoApprovalRule already advanced the Job
      # to :approved before the workflow succeeds. workflow.succeed
      # must not regress it back.
      job.update!(state: "approved", approved_at: Time.current, approved_via: "operator")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)

      expect { wf.succeed!; wf.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("approved")
    end
  end

  describe "#fail cancels orphan active Runs but preserves Steps" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "moves queued/running Runs to :cancelled and leaves queued Steps alone (for retry-from-failed-step)" do
      done_step    = Step.create!(workflow: wf, kind: "prepare",   position: 0, state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      failed_step  = Step.create!(workflow: wf, kind: "implement", position: 1, state: "failed",    started_at: 1.minute.ago, finished_at: Time.current)
      queued_step  = Step.create!(workflow: wf, kind: "summarize", position: 2)  # queued — orphan tail
      tail_step    = Step.create!(workflow: wf, kind: "pr_open",   position: 3)  # queued — orphan tail

      done_run    = Run.create!(job: job, step: done_step,   trigger_kind: "initial", state: "succeeded")
      failed_run  = Run.create!(job: job, step: failed_step, trigger_kind: "initial", state: "failed")
      orphan_run  = Run.create!(job: job, step: queued_step, trigger_kind: "initial")  # queued — speculatively created

      wf.start!
      wf.fail!
      wf.save!

      expect(wf).to be_failed

      # Orphan active Run gets cancelled so Job#any_active_run? clears
      # and the Retry button reappears in the UI.
      expect(orphan_run.reload.state).to eq("cancelled")
      expect(orphan_run.finished_at).to be_present

      # Queued tail Steps stay queued so Retry-from-failed-step can
      # reopen the failed Step and the dispatcher can advance through
      # the chain.
      expect(queued_step.reload.state).to eq("queued")
      expect(tail_step.reload.state).to   eq("queued")

      # Already-terminal records are untouched.
      expect(done_step.reload.state).to   eq("succeeded")
      expect(done_run.reload.state).to    eq("succeeded")
      expect(failed_step.reload.state).to eq("failed")
      expect(failed_run.reload.state).to  eq("failed")
    end

    it "is idempotent — failing twice doesn't crash when there are no orphan Runs left" do
      Step.create!(workflow: wf, kind: "implement", position: 0, state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
      wf.start!
      wf.fail!
      wf.save!
      expect { wf.cancel_orphan_active_runs! }.not_to raise_error
    end

    it "does NOT cleanup the workspace (deliberate — retry-from-failed-step needs it)" do
      Step.create!(workflow: wf, kind: "implement", position: 0, state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
      wf.start!
      expect(WorkflowWorkspace).not_to receive(:cleanup_for)
      wf.fail!
      wf.save!
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

  describe "#succeed (Rebase → AutoMerge handoff)" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

    def landing_job
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "implemented")
      job.approve!(via: "github_review")
      job
    end

    it "calls LandingQueueProcessor.try_land! when a rebase workflow succeeds on an approved Job" do
      job = landing_job
      rebase_wf = Workflows::Rebase.instantiate(job: job)
      rebase_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      rebase_wf.succeed!
      rebase_wf.save!

      expect(LandingQueueProcessor).to have_received(:try_land!).with(job)
    end

    it "skips LandingQueueProcessor.try_land! when the succeeding workflow is not a rebase" do
      job = landing_job
      initial_wf = described_class.create!(job: job, trigger_kind: "initial", state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      initial_wf.succeed!
      initial_wf.save!

      expect(LandingQueueProcessor).not_to have_received(:try_land!)
    end

    it "skips LandingQueueProcessor.try_land! when the Job is no longer approved" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "queued")
      rebase_wf = Workflows::Rebase.instantiate(job: job)
      rebase_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      rebase_wf.succeed!
      rebase_wf.save!

      expect(LandingQueueProcessor).not_to have_received(:try_land!)
    end

    it "swallows hook exceptions so the workflow state transition still commits" do
      job = landing_job
      rebase_wf = Workflows::Rebase.instantiate(job: job)
      rebase_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!).and_raise(StandardError, "boom")

      expect {
        rebase_wf.succeed!
        rebase_wf.save!
      }.not_to raise_error

      expect(rebase_wf.reload).to be_succeeded
    end
  end

  describe "#succeed (AutoMerge → next landing handoff)" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

    it "kicks the landing queue once when an auto_merge workflow succeeds" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "landing")
      auto_merge_wf = Workflows::AutoMerge.instantiate(job: job)
      auto_merge_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      auto_merge_wf.succeed!
      auto_merge_wf.save!

      expect(LandingQueueProcessor).to have_received(:try_land!).once.with(no_args)
    end
  end

  describe "#dispatch_hook (workflow-class hook dispatcher)" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "invokes the hook method on the matching Workflows::* template class" do
      allow(Workflows::Initial).to receive(:after_success)

      wf.send(:dispatch_hook, :after_success)

      expect(Workflows::Initial).to have_received(:after_success).with(wf)
    end

    it "logs and swallows exceptions raised by the hook" do
      allow(Workflows::Initial).to receive(:after_success).and_raise(StandardError, "boom")
      allow(Rails.logger).to receive(:warn)

      expect { wf.send(:dispatch_hook, :after_success) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/after_success hook raised.*StandardError.*boom/)
    end

    it "no-ops for an unknown trigger_kind without raising" do
      wf.update_column(:trigger_kind, "no_longer_registered")

      expect { wf.send(:dispatch_hook, :after_success) }.not_to raise_error
    end
  end

  describe "Workflows::PrFeedback.after_success" do
    let(:job) { Factories.job }
    let(:wf) do
      described_class.create!(
        job: job,
        trigger_kind: "pr_comment",
        artifacts: { "pr_comments" => [
          { "id" => 1, "created_at" => "2026-05-17T18:00:00Z" },
          { "id" => 2, "created_at" => "2026-05-17T20:30:00Z" }
        ] }
      )
    end

    it "marks the job's feedback as addressed at the latest comment timestamp" do
      Workflows::PrFeedback.after_success(wf)

      expect(job.reload.last_feedback_addressed_at).to be_within(1.second).of(Time.iso8601("2026-05-17T20:30:00Z"))
    end

    it "is a no-op when artifacts has no pr_comments" do
      wf.update!(artifacts: {})

      expect { Workflows::PrFeedback.after_success(wf) }.not_to change { job.reload.last_feedback_addressed_at }
    end
  end
end
