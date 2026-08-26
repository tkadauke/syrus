require "rails_helper"
require Rails.root.join("db/migrate/20260826190444_add_delivery_track_to_jobs")

RSpec.describe AddDeliveryTrackToJobs, :ci_only do
  it "is idempotent when run more than once" do
    migration = described_class.new

    expect {
      migration.change
      migration.change
    }.not_to raise_error

    expect(ActiveRecord::Base.connection.column_exists?(:jobs, :delivery_track)).to eq(true)
  end
end
