require "rails_helper"
require Rails.root.join("db/migrate/20261017221640_remove_user_daily_spend_budget_from_app_settings")

RSpec.describe RemoveUserDailySpendBudgetFromAppSettings, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.up
    AppSetting.reset_column_information
  end

  it "removes the application-owned daily spend ceiling" do
    migration.down
    AppSetting.reset_column_information
    expect(app_setting_column_names).to include("user_daily_spend_budget_usd")
    expect(AppSetting.ignored_columns).to include("user_daily_spend_budget_usd")
    expect(ActiveRecord::Base.connection.index_exists?(
      :runs,
      described_class::SPEND_WINDOW_COLUMNS,
      name: described_class::SPEND_WINDOW_INDEX
    )).to be(true)
    AppSetting.columns

    migration.up
    AppSetting.delete_all

    expect { AppSetting.current }.not_to raise_error

    expect(app_setting_column_names).not_to include("user_daily_spend_budget_usd")
    expect(ActiveRecord::Base.connection.index_exists?(
      :runs,
      described_class::SPEND_WINDOW_COLUMNS,
      name: described_class::SPEND_WINDOW_INDEX
    )).to be(false)
  end

  def app_setting_column_names
    ActiveRecord::Base.connection.columns(:app_settings).map(&:name)
  end
end
