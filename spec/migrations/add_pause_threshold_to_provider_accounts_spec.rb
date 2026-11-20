require "rails_helper"
require Rails.root.join("db/migrate/20261119224806_add_pause_threshold_to_provider_accounts")

RSpec.describe AddPauseThresholdToProviderAccounts, :ci_only do
  it "is idempotent and adds the account override column" do
    migration = described_class.new

    expect { migration.migrate(:up) }.not_to raise_error
    expect { migration.migrate(:up) }.not_to raise_error

    column = ActiveRecord::Base.connection.columns(:provider_accounts).find { |candidate| candidate.name == "proactive_pause_threshold" }
    expect(column).to be_present
  end
end
