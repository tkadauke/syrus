require "rails_helper"

RSpec.describe App::DashboardChromeCache do
  it "does not break model commits when the cache store is unavailable" do
    allow(Rails.cache).to receive(:write).and_raise(ActiveRecord::StatementInvalid, "cache schema is unavailable")
    allow(Rails.logger).to receive(:warn)

    expect { described_class.invalidate_all! }.not_to raise_error
    expect { described_class.invalidate_user!(123) }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).twice.with(/Dashboard chrome cache invalidation skipped/)
  end
end
