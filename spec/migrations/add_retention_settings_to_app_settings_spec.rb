require "rails_helper"
require Rails.root.join("db/migrate/20260916144445_add_retention_settings_to_app_settings")

RSpec.describe AddRetentionSettingsToAppSettings, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  # The values this migration introduced are deliberately NOT pinned here.
  # A later migration is allowed to move one -- ReduceMetricsDashboardSampleRetention
  # took metrics_dashboard_sample_retention_days from 30 to 7 on purpose, and
  # has its own spec covering that -- and comparing a current default against
  # the constants of an old migration turns every such change into a failure in
  # an unrelated spec about a migration that did nothing wrong. It did exactly
  # that: `expected 30, got 7` was one of three examples keeping main red, and
  # every merge train paid for it.
  #
  # What this migration is responsible for is that the columns exist and are
  # non-null with a default. Which default is current belongs to the schema and
  # to the spec of whichever migration last set it.
  it "adds every retention column as non-null with a default" do
    setting = AppSetting.new

    described_class::COLUMNS.each_key do |column|
      expect(connection.column_exists?(:app_settings, column)).to eq(true)

      definition = connection.columns(:app_settings).find { |c| c.name == column.to_s }
      expect(definition.null).to eq(false), "#{column} should be NOT NULL"
      expect(definition.default).not_to be_nil, "#{column} should have a database default"
      expect(setting.public_send(column)).to be_a(Integer)
    end
  end

  it "is idempotent when run more than once" do
    expect {
      migration.up
      migration.up
    }.not_to raise_error

    described_class::COLUMNS.each_key do |column|
      expect(connection.column_exists?(:app_settings, column)).to eq(true)
    end
  end

  it "has a down migration that removes the columns" do
    migration.up
    migration.down
    connection.schema_cache.clear!

    described_class::COLUMNS.each_key do |column|
      expect(connection.column_exists?(:app_settings, column)).to eq(false)
    end
  ensure
    # Restore schema state for any example that runs after this one in the
    # same process (down drops columns the rest of the suite expects).
    migration.up
    connection.schema_cache.clear!
    AppSetting.reset_column_information
  end
end
