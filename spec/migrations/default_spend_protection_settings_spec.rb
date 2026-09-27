require "rails_helper"
require Rails.root.join("db/migrate/20260927223533_default_spend_protection_settings")

RSpec.describe DefaultSpendProtectionSettings, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.up
    AppSetting.reset_column_information
  end

  it "changes fresh-row defaults without rewriting an existing explicit zero" do
    migration.down
    AppSetting.reset_column_information
    AppSetting.delete_all
    setting = AppSetting.create!(
      singleton_key: AppSetting::SINGLETON_KEY,
      max_concurrent_agent_runs: 0,
      user_daily_spend_budget_usd: 0
    )

    migration.up
    AppSetting.reset_column_information

    expect(setting.reload.max_concurrent_agent_runs).to eq(0)
    expect(setting.user_daily_spend_budget_usd).to eq(0)
    expect(AppSetting.new.max_concurrent_agent_runs)
      .to eq(described_class::DEFAULT_MAX_CONCURRENT_AGENT_RUNS)
    expect(AppSetting.new.user_daily_spend_budget_usd)
      .to eq(described_class::DEFAULT_USER_DAILY_SPEND_BUDGET_USD)
  end
end
