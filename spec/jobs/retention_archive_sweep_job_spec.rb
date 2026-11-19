require "rails_helper"

RSpec.describe RetentionArchiveSweepJob do
  it "uses the consumed cleanup queue" do
    expect(described_class.queue_name).to eq("cleanup")
  end

  it "fans out only archive-enabled definitions discovered through the registry" do
    set_retention_archive(:run_diagnostic, true)
    definitions = [
      RetentionPolicyRegistry.fetch(:notification),
      RetentionPolicyRegistry.fetch(:run_diagnostic)
    ]
    allow(RetentionPolicyRegistry).to receive(:definitions).and_return(definitions)

    described_class.perform_now

    expect(RetentionPolicyPruneJob).to have_been_enqueued.with("run_diagnostic", true).once
    expect(RetentionPolicyPruneJob).not_to have_been_enqueued.with("notification", true)
  end

  it "includes an enabled plugin-contributed definition without a policy-specific schedule" do
    definition = instance_double(
      RetentionPolicyRegistry::Definition,
      key: :plugin_archive,
      default_seconds: 1.day.to_i,
      archivable: true
    )
    RetentionPolicySetting.create!(
      retention_key: "plugin_archive",
      retention_seconds: 1.day.to_i,
      archive_before_delete: true
    )
    allow(RetentionPolicyRegistry).to receive(:definitions).and_return([ definition ])

    described_class.perform_now

    expect(RetentionPolicyPruneJob).to have_been_enqueued.with("plugin_archive", true).once
  end
end
