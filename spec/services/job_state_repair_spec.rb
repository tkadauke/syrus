require "rails_helper"

RSpec.describe JobStateRepair do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def build_job(state, **attrs)
    Factories.job_record(state: state, repository: repository, user: user, **attrs)
  end

  def terminal_workflow_for(job, state: "succeeded")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude")
    workflow.update_columns(state: state, finished_at: Time.current)
    workflow
  end

  def active_workflow_for(job)
    Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude")
  end

  describe ".reconcile!" do
    context "with an unknown mode" do
      it "raises ArgumentError" do
        job = build_job("failed")
        expect { described_class.reconcile!(mode: :undefined, job: job, reason: "test") }
          .to raise_error(ArgumentError, /unknown reconciliation mode: undefined/)
      end
    end

    context "auto mode" do
      it "delegates to WorkEngine::Reconciler and returns a Result" do
        job = build_job("failed")
        allow(WorkEngine::Reconciler).to receive(:call).and_return(
          WorkEngine::Reconciler::Result.new(
            source: "test", captured_at: Time.current, snapshot: nil,
            issues: [], repair_plans: [], repair_executions: []
          )
        )

        result = described_class.reconcile!(mode: :auto, job: job, reason: "operator triggered")

        expect(result).to be_a(described_class::Result)
        expect(result.job).to eq(job)
        expect(result.message).to include("WorkEngine reconciler")
        expect(result.message).to include("0 repair")
      end
    end

    context "mark_implemented_from_ready_pr mode" do
      it "raises when the job has no PR recorded" do
        job = build_job("running")
        terminal_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "fix") }
          .to raise_error(ArgumentError, /no PR recorded/)
      end

      it "raises when the job has an active workflow" do
        job = build_job("running", pr_number: 1)
        active_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "fix") }
          .to raise_error(ArgumentError, /still has active work/)
      end

      it "raises when the job has no terminal latest workflow" do
        job = build_job("running", pr_number: 1)

        expect { described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "fix") }
          .to raise_error(ArgumentError, /no terminal latest workflow/)
      end

      it "transitions from failed to implemented via retry_after_failure + mark_implemented" do
        job = build_job("failed", pr_number: 1)
        terminal_workflow_for(job, state: "failed")

        result = described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "manual reconcile")

        expect(result.job.reload.state).to eq("implemented")
        expect(result.message).to include("implemented")
        expect(result.message).to include(job.slug)
      end

      it "transitions from queued to implemented" do
        job = build_job("queued", pr_number: 1)
        terminal_workflow_for(job)

        result = described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "reconcile")

        expect(result.job.reload.state).to eq("implemented")
      end

      it "transitions from running to implemented" do
        job = build_job("running", pr_number: 1)
        terminal_workflow_for(job)

        result = described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "reconcile")

        expect(result.job.reload.state).to eq("implemented")
      end

      it "accepts external_pr_number as an alternative to pr_number" do
        job = build_job("running", external_pr_number: 99)
        terminal_workflow_for(job)

        result = described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "reconcile")

        expect(result.job.reload.state).to eq("implemented")
      end

      it "raises when called on an already-implemented job" do
        job = build_job("implemented", pr_number: 1)
        terminal_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "fix") }
          .to raise_error(ArgumentError, /expected queued, running, or failed/)
      end

      it "records a StateTransition with reconciler source" do
        job = build_job("running", pr_number: 1)
        terminal_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_implemented_from_ready_pr, job: job, reason: "fix") }
          .to change { StateTransition.where(subject: job, source: "reconciler").count }.by_at_least(1)
      end
    end

    context "mark_failed mode" do
      it "raises when the job has an active workflow" do
        job = build_job("running")
        active_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_failed, job: job, reason: "stuck") }
          .to raise_error(ArgumentError, /still has active work/)
      end

      it "transitions from running to failed" do
        job = build_job("running")
        terminal_workflow_for(job)

        result = described_class.reconcile!(mode: :mark_failed, job: job, reason: "stuck run")

        expect(result.job.reload.state).to eq("failed")
        expect(result.message).to include("failed")
        expect(result.message).to include(job.slug)
      end

      it "transitions from queued to failed via start_running + mark_failed" do
        job = build_job("queued")
        terminal_workflow_for(job)

        result = described_class.reconcile!(mode: :mark_failed, job: job, reason: "stuck queue")

        expect(result.job.reload.state).to eq("failed")
      end

      it "raises when called on an implemented job" do
        job = build_job("implemented")
        terminal_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_failed, job: job, reason: "stuck") }
          .to raise_error(ArgumentError, /expected queued or running/)
      end

      it "raises when called on an already-failed job" do
        job = build_job("failed")
        terminal_workflow_for(job, state: "failed")

        expect { described_class.reconcile!(mode: :mark_failed, job: job, reason: "stuck") }
          .to raise_error(ArgumentError, /expected queued or running/)
      end

      it "records a StateTransition with reconciler source" do
        job = build_job("running")
        terminal_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_failed, job: job, reason: "fix") }
          .to change { StateTransition.where(subject: job, source: "reconciler").count }.by_at_least(1)
      end
    end

    context "mark_queued mode" do
      it "raises when the job has an active workflow" do
        job = build_job("failed")
        active_workflow_for(job)

        expect { described_class.reconcile!(mode: :mark_queued, job: job, reason: "retry") }
          .to raise_error(ArgumentError, /still has active work/)
      end

      it "raises when the job cannot retry after failure" do
        job = build_job("implemented")

        expect { described_class.reconcile!(mode: :mark_queued, job: job, reason: "retry") }
          .to raise_error(ArgumentError, /cannot be marked queued/)
      end

      it "transitions from failed to queued" do
        job = build_job("failed")
        terminal_workflow_for(job, state: "failed")

        result = described_class.reconcile!(mode: :mark_queued, job: job, reason: "operator retry")

        expect(result.job.reload.state).to eq("queued")
        expect(result.message).to include("queued")
        expect(result.message).to include(job.slug)
      end

      it "records a StateTransition with reconciler source" do
        job = build_job("failed")
        terminal_workflow_for(job, state: "failed")

        expect { described_class.reconcile!(mode: :mark_queued, job: job, reason: "retry") }
          .to change { StateTransition.where(subject: job, source: "reconciler").count }.by_at_least(1)
      end
    end
  end

  describe ".force_transition!" do
    it "raises for events not in the allowlist" do
      job = build_job("queued")

      expect { described_class.force_transition!(job: job, event: "create_initial_run", reason: "hack") }
        .to raise_error(ArgumentError, /event is not allowed: create_initial_run/)
    end

    it "raises when the allowed event cannot be applied from the current state" do
      job = build_job("queued")

      # approve transitions from implemented only
      expect { described_class.force_transition!(job: job, event: "approve", reason: "force") }
        .to raise_error(ArgumentError, /cannot apply approve from queued/)
    end

    it "applies retry_after_failure from failed to queued" do
      job = build_job("failed")
      terminal_workflow_for(job, state: "failed")

      result = described_class.force_transition!(job: job, event: "retry_after_failure", reason: "operator fix")

      expect(result.job.reload.state).to eq("queued")
      expect(result.message).to include("retry_after_failure")
      expect(result.message).to include(job.slug)
      expect(result.message).to include("failed")
      expect(result.message).to include("queued")
    end

    it "applies force_fail from implemented to failed" do
      job = build_job("implemented")

      result = described_class.force_transition!(job: job, event: "force_fail", reason: "operator")

      expect(result.job.reload.state).to eq("failed")
    end

    it "applies close from failed to closed" do
      job = build_job("failed")

      result = described_class.force_transition!(job: job, event: "close", reason: "obsolete")

      expect(result.job.reload.state).to eq("closed")
    end

    it "applies mark_no_change_needed from running" do
      job = build_job("running")

      result = described_class.force_transition!(job: job, event: "mark_no_change_needed", reason: "survey complete")

      expect(result.job.reload.state).to eq("no_change_needed")
    end

    it "records a StateTransition with reconciler source" do
      job = build_job("failed")

      expect { described_class.force_transition!(job: job, event: "retry_after_failure", reason: "fix") }
        .to change { StateTransition.where(subject: job, source: "reconciler").count }.by_at_least(1)
    end
  end
end
