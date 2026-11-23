require "rails_helper"

# Regression: a provider candidate that is available through legacy/default
# credentials with no enabled ProviderAccount used to make
# AvailabilitySelector call `public_id` on a nil account, raising
# NoMethodError from both deferred phase admission and Run execution.
RSpec.describe "account-less provider selection at job entry points" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:noop_handler_class) { Class.new(Steps::Base) { def call; nil; end } }

  before do
    allow_any_instance_of(User).to receive(:enabled_provider_accounts).and_return(ProviderAccount.none)
    allow(App::ProviderAvailability).to receive(:for_user).and_return(state: "available")
    allow_any_instance_of(ProviderRouting::AvailabilitySelector).to receive(:credential_unavailability).and_return(nil)
    allow(Steps).to receive(:handler_for).and_return(noop_handler_class)
    allow(RunHostAdmission).to receive(:call) do |run:, **|
      RunHostAdmission::Decision.new(action: "admit", reason: "test", delay: nil, details: { "run_id" => run.id })
    end
    # The first step is awaiting its Run, so admission must route a provider.
    workflow.first_step.runs.destroy_all
    clear_enqueued_jobs
  end

  describe WorkflowPhaseAdmissionJob do
    it "starts the deferred phase instead of raising NoMethodError" do
      expect(ProviderRouting::AvailabilitySelector).to receive(:call).at_least(:once).and_call_original

      expect {
        described_class.perform_now(workflow.id, workflow.first_step.id)
      }.not_to raise_error

      expect(workflow.first_step.reload.runs.count).to eq(1)
    end
  end

  describe RunJob do
    it "admits the successor Step through account-less provider selection instead of raising NoMethodError" do
      # Build the first Run directly so nothing routes a provider before
      # RunJob starts; the selector must first be reached from inside RunJob.
      first_step = workflow.first_step
      run = first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      workflow.update_columns(state: "running", started_at: Time.current)
      clear_enqueued_jobs

      expect(ProviderRouting::AvailabilitySelector).to receive(:call).at_least(:once).and_call_original

      expect { described_class.perform_now(run.id) }.not_to raise_error

      expect(run.reload.state).to eq("succeeded")
      expect(workflow.steps.where.not(id: first_step.id).joins(:runs).count).to be >= 1
    end
  end
end
