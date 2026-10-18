require "rails_helper"
require Rails.root.join("db/migrate/20261018005611_bound_local_workspace_storage_defaults")

RSpec.describe BoundLocalWorkspaceStorageDefaults, :ci_only do
  let(:migration) { described_class.new }

  it "changes fresh-record defaults without rewriting existing settings" do
    setting = AppSetting.current
    setting.update!(prepared_layer_cache_gb: 7, chat_coding_workspace_budget_mb: 0)

    migration.down
    migration.up
    migration.up
    AppSetting.reset_column_information

    expect(setting.reload).to have_attributes(
      prepared_layer_cache_gb: 7,
      chat_coding_workspace_budget_mb: 0
    )
    expect(AppSetting.new).to have_attributes(
      prepared_layer_cache_gb: 10,
      chat_coding_workspace_budget_mb: 10_240
    )
  ensure
    migration.up
    AppSetting.reset_column_information
  end
end
