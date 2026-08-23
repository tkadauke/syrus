require "rails_helper"

RSpec.describe WorkflowActivity do
  around do |example|
    Dir.mktmpdir("syrus-workflow-activity-spool") do |dir|
      previous = ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"]
      ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"] = dir
      Observability::EventSink.clear!(kind: :workflow_activity)
      example.run
      Observability::EventSink.clear!(kind: :workflow_activity)
    ensure
      ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"] = previous
    end
  end

  it "records workflow and run lifecycle events through the observability sink" do
    job = Factories.job_record(state: "queued")
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "codex")
    step = workflow.steps.create!(kind: "implement", position: 1)
    run = Run.create!(job: job, user: job.user, step: step, trigger_kind: "initial", agent_provider: "codex")

    described_class.synchronously do
      described_class.workflow_created!(workflow)
      workflow.start!
      workflow.save!
      described_class.workflow_state_changed!(workflow)
      run.start!
      run.save!
      described_class.run_state_changed!(run)
      run.succeed!
      run.save!
      described_class.run_state_changed!(run)
    end

    expect(WorkflowActivityEvent.where(workflow_id: workflow.id).pluck(:event_type)).to include("workflow_created", "workflow_started", "run_started", "run_finished")
    expect(WorkflowActivityEvent.find_by!(event_type: "run_finished", run_id: run.id).duration_ms).to be >= 0
  end

  it "records workflow transition reasons on activity events" do
    job = Factories.job_record(state: "queued")
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "codex")

    described_class.synchronously do
      workflow.start!
      workflow.save!
      workflow.failure_reason = "pr_publication_missing_after_success"
      workflow.fail!
      workflow.save!
    end

    event = WorkflowActivityEvent.find_by!(event_type: "workflow_finished", workflow_id: workflow.id)
    expect(event).to have_attributes(
      severity: "error",
      reason_key: "pr_publication_missing_after_success"
    )
    expect(event.metadata).to include(
      "failure_reason" => "pr_publication_missing_after_success",
      "reason_key" => "pr_publication_missing_after_success"
    )
  end

  it "deduplicates repeated lifecycle events before persisting them" do
    job = Factories.job_record(state: "queued")
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "codex")
    step = workflow.steps.create!(kind: "implement", position: 1)
    run = Run.create!(job: job, user: job.user, step: step, trigger_kind: "initial", agent_provider: "codex")
    occurred_at = Time.current
    event = WorkflowActivityEvent.from_event_hash(
      "event_type" => "run_started",
      "source" => "run",
      "severity" => "info",
      "occurred_at" => occurred_at.iso8601(6),
      "job_id" => job.id,
      "workflow_id" => workflow.id,
      "step_id" => step.id,
      "run_id" => run.id,
      "trigger_kind" => "initial",
      "workflow_state" => "running",
      "step_kind" => "implement",
      "run_state" => "running",
      "message" => "Run ##{run.id} queued -> running.",
      "metadata" => {
        "from_state" => "queued",
        "to_state" => "running",
        "step_kind" => "implement",
        "trigger_kind" => "initial"
      }
    )

    expect {
      WorkflowActivityEvent.persist_observability_events!([ event, event.merge(occurred_at: occurred_at + 1.second) ], batch_size: 10)
      WorkflowActivityEvent.persist_observability_events!([ event.merge(occurred_at: occurred_at + 2.seconds) ], batch_size: 10)
    }.to change { WorkflowActivityEvent.where(event_type: "run_started", run_id: run.id).count }.by(1)
  end
end
