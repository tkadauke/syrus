require "rails_helper"

RSpec.describe Coworkers::ReviewContextRetentionPolicy do
  it "registers restricted reviewer context with the shared retention registry" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    definition = described_class.retention_definitions.fetch(0)

    expect(definition).to have_attributes(key: :coworker_review_context, model: "Coworkers::ReviewContext",
      scope_name: :retention_candidates, default_value: 30,
      executor_class: "Coworkers::ReviewContextRetentionExecutor", archivable: false)
    expect(RetentionPolicyRegistry.definitions.map(&:key)).to include(:coworker_review_context)
    expect(RetentionPolicyRegistry::CORE_DEFINITIONS.map(&:key)).not_to include(:coworker_review_context)
  end
end
