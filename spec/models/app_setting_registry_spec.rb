require "rails_helper"

RSpec.describe AppSettingRegistry do
  it "covers every persisted AppSetting column except Rails bookkeeping" do
    registry_keys = described_class.definitions.map(&:key).map(&:to_s)
    persisted_keys = AppSetting.column_names - %w[id created_at updated_at]

    expect(registry_keys).to contain_exactly(*persisted_keys)
  end

  it "matches current AppSetting defaults" do
    setting = AppSetting.new

    described_class.definitions.each do |definition|
      expect(setting.public_send(definition.key)).to eq(definition.default)
    end
  end

  it "exposes validation and zero-semantics metadata for integer settings" do
    expect(described_class.fetch(:grade_max_iterations).numericality_options).to include(
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 10
    )
    expect(described_class.fetch(:video_storage_budget_mb).zero_means).to eq("Size cap is disabled; time-based retention still applies.")
    expect(described_class.fetch(:max_concurrent_agent_runs).zero_means).to include("No global cap")
  end

  it "declares the current admin settings payload metadata" do
    expect(described_class.admin_editable_keys).to eq([
      :signups_open,
      :max_concurrent_agent_runs,
      :proactive_rebase_commit_threshold,
      :video_retention_days,
      :video_storage_budget_mb
    ])

    expect(described_class.metadata_for([ :proactive_rebase_commit_threshold ])).to eq([
      {
        key: "proactive_rebase_commit_threshold",
        type: "integer",
        default: 20,
        category: "Instance operations",
        operational_meaning: "Commits-behind threshold that triggers proactive PR rebase maintenance while mergeability is still clean.",
        min: 1,
        admin_editable: true,
        secret: false
      }
    ])
  end
end
