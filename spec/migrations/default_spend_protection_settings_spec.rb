require "rails_helper"
require Rails.root.join("db/migrate/20261013024742_default_user_daily_spend_budget")
require Rails.root.join("db/migrate/20260927223533_default_spend_protection_settings")
require Rails.root.join("db/migrate/20260904134705_add_user_daily_spend_budget_to_app_settings")

RSpec.describe DefaultSpendProtectionSettings, :ci_only do
  let(:migration) { described_class.new }
  let(:budget_migration) { AddUserDailySpendBudgetToAppSettings.new }
  let(:user_budget_migration) { DefaultUserDailySpendBudget.new }

  after do
    budget_migration.up
    migration.up
    user_budget_migration.up
    AppSetting.reset_column_information
  end

  it "defaults spend protections without rewriting existing explicit zeros" do
    user_budget_migration.down
    migration.down
    budget_migration.up
    AppSetting.reset_column_information
    AppSetting.delete_all
    setting = AppSetting.create!(
      singleton_key: AppSetting::SINGLETON_KEY,
      max_concurrent_agent_runs: 0,
      user_daily_spend_budget_usd: 0
    )

    migration.up
    user_budget_migration.up
    AppSetting.reset_column_information

    expect(setting.reload.max_concurrent_agent_runs).to eq(0)
    expect(setting.user_daily_spend_budget_usd).to eq(0)
    expect(AppSetting.new.max_concurrent_agent_runs)
      .to eq(described_class::DEFAULT_MAX_CONCURRENT_AGENT_RUNS)
    expect(AppSetting.new.user_daily_spend_budget_usd)
      .to eq(DefaultUserDailySpendBudget::DEFAULT_USER_DAILY_SPEND_BUDGET_USD)
  end
end
