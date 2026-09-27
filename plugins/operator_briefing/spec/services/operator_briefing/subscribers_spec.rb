require "rails_helper"

RSpec.describe OperatorBriefing::Subscribers do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.workflows.first }

  it "persists detected notable-change facts idempotently" do
    event = Syrus::DomainEvent.new(
      name: "operator_briefing.notable_changes_detected",
      payload: {
        workflow_id: workflow.id,
        facts: [
          {
            "key" => "schema:schema_or_migration_changed",
            "severity" => "decision_required",
            "summary" => "Schema changed.",
            "evidence" => [ { "file" => "db/schema.rb" } ]
          }
        ]
      }
    )

    2.times { described_class.on_notable_changes_detected(event) }

    expect(OperatorBriefing::WorkflowNotableChange.count).to eq(1)
    change = OperatorBriefing::WorkflowNotableChange.first
    expect(change).to have_attributes(
      workflow: workflow,
      job: job,
      repository: job.repository,
      detector_key: "schema",
      fact_key: "schema:schema_or_migration_changed",
      severity: "decision_required",
      summary: "Schema changed."
    )
    expect(change.evidence).to eq([ { "file" => "db/schema.rb" } ])
  end

  it "persists promoted review findings from the review event" do
    run = workflow.steps.first.runs.first
    event = Syrus::DomainEvent.new(
      name: "operator_briefing.review_finding_recorded",
      payload: {
        workflow_id: workflow.id,
        step_id: run.step_id,
        run_id: run.id,
        review_kind: "adversarial",
        iteration: 1,
        verdict: "needs_work",
        critique: "Missing edge case.",
        skipped: true,
        skip_reason: "missing_required_tool_call"
      }
    )

    described_class.on_review_finding_recorded(event)

    expect(OperatorBriefing::ReviewFinding.last).to have_attributes(
      workflow: workflow,
      step: run.step,
      run: run,
      review_kind: "adversarial",
      verdict: "needs_work",
      critique: "Missing edge case.",
      skipped: true,
      skip_reason: "missing_required_tool_call"
    )
  end
end
