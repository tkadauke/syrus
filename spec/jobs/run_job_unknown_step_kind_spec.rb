require "rails_helper"

# Routing sends a Run to a queue every worker of that OS consumes, so during a
# fleet plugin rollout (or for a fleet installation limited to some roles) a
# worker without the plugin can claim a Run of that plugin's step kind. It used
# to fail the Step outright in Steps.handler_for. A worker that does not know
# the step's kind now hands the Run back for one that does, for a bounded
# number of tries, before the Step fails as unknown (NY17,
# formal/SyrusModel/UnknownKindHandback.lean).
RSpec.describe RunJob, "with a step kind this worker does not provide" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job_with_run(state: "running", workflow_attrs: { state: "running" }) }
  let(:step) { job.workflows.first.steps.first }
  let(:run) { step.runs.first }

  before do
    step.update_columns(kind: "fleet_plugin_only_step")
    expect(Step::Kind.values).not_to include("fleet_plugin_only_step")
  end

  it "hands the Run back for another worker instead of failing it" do
    expect {
      described_class.perform_now(run.id)
    }.to have_enqueued_job(described_class).with(run.id)

    expect(run.reload).to be_queued
    expect(step.reload).to be_queued
    expect(step.details["unknown_kind_handbacks"]).to eq(1)
  end

  it "fails the Step as unknown once no worker has taken it within the budget" do
    step.update_columns(details: step.details.to_h.merge("unknown_kind_handbacks" => described_class::UNKNOWN_KIND_HANDBACK_LIMIT))

    expect {
      begin
        described_class.perform_now(run.id)
      rescue ArgumentError
        nil
      end
    }.not_to have_enqueued_job(described_class).with(run.id)

    expect(run.reload).to be_failed
  end
end
