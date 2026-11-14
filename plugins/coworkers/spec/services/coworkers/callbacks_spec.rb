require "rails_helper"

RSpec.describe Coworkers::Callbacks do
  it "schedules bounded branch retention from the plugin tick" do
    allow(Coworkers::ProvisioningReconciler).to receive(:call)

    expect { described_class.on_tick }.to have_enqueued_job(Coworkers::BranchRetentionSweepJob).on_queue("cleanup")
  end
end
