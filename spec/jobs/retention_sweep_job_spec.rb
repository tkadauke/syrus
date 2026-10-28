require "rails_helper"

RSpec.describe RetentionSweepJob do
  it "uses the consumed cleanup queue" do
    expect(described_class.queue_name).to eq("cleanup")
    expect(RetentionPolicyPruneJob.queue_name).to eq("cleanup")
  end

  it "fans out one stable-key job for every active definition" do
    definitions = [
      RetentionPolicyRegistry.fetch(:notification),
      RetentionPolicyRegistry.fetch(:run_diagnostic)
    ]
    allow(RetentionPolicyRegistry).to receive(:definitions).and_return(definitions)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    described_class.perform_now

    expect(RetentionPolicyPruneJob).to have_been_enqueued.with("notification").once
    expect(RetentionPolicyPruneJob).to have_been_enqueued.with("run_diagnostic").once
  end

  it "does not enqueue policies contributed by a disabled plugin" do
    PluginRecord.find_or_create_by!(name: "metrics_dashboard").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    described_class.perform_now

    expect(RetentionPolicyPruneJob).not_to have_been_enqueued.with("metrics_dashboard_sample")
  end
end
