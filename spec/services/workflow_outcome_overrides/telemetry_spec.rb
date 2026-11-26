require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::Telemetry do
  it "records a metric, operational audit, and transcript marker for consumed evidence" do
    exposed_token = "ghp_#{'a' * 24}"
    run = instance_double(Run)
    runs = instance_double(ActiveRecord::Associations::CollectionProxy)
    ordered_runs = instance_double(ActiveRecord::Relation, last: run)
    step = instance_double(Step, runs: runs)
    actor = instance_double(User, class: User, id: 9)
    override = instance_double(
      WorkflowOutcomeOverride,
      id: 7, job_id: 3, workflow_id: 4, step_id: 5, step:, actor:,
      actor_type: "User", actor_id: 9, gate_kind: "implementation_grader",
      gate_identity: "rspec\nBearer #{exposed_token}", candidate_head_sha: "a" * 40,
      evidence_digest: "b" * 64, channel: "ui"
    )
    counter = instance_double(Syrus::Metrics::Counter, increment: nil)
    allow(runs).to receive(:order).with(:created_at).and_return(ordered_runs)
    allow(Syrus::Metrics).to receive(:counter).and_return(counter)
    allow(OperationalLogging).to receive(:ingest)
    allow(JobLog).to receive(:append!)

    described_class.record_consumed(override)

    expect(counter).to have_received(:increment).with(tags: { kind: "implementation_grader", source: "ui" })
    expect(OperationalLogging).to have_received(:ingest).with(hash_including(
      source: "workflow_outcome_override", message: "Workflow outcome failed, overridden",
      context: hash_including(outcome_override_id: 7, job_id: 3, workflow_id: 4)
    ))
    expect(JobLog).to have_received(:append!).with(hash_including(run:, kind: "workflow_outcome_override")) do |attributes|
      expect(attributes[:chunk]).to include("failed, overridden", "rspec", ToolPayloadRedactor::REDACTED)
      expect(attributes[:chunk]).not_to include(exposed_token)
      expect(attributes[:chunk].lines.size).to eq(1)
    end
  end
end
