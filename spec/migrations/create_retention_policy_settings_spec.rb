require "rails_helper"
require Rails.root.join("db/migrate/20261028143228_create_retention_policy_settings")

RSpec.describe CreateRetentionPolicySettings, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  it "restores legacy defaults while round-tripping persisted operator choices" do
    RetentionPolicySetting.find_or_initialize_by(retention_key: "job_log").update!(
      retention_seconds: 12.days.to_i,
      archive_before_delete: true
    )
    RetentionPolicySetting.find_or_initialize_by(retention_key: "notification").update!(
      retention_seconds: nil,
      archive_before_delete: nil
    )

    migration.migrate(:down)
    reset_app_setting_columns

    existing = AppSetting.current.reload
    expect(existing.job_log_retention_days).to eq(12)
    expect(existing.job_log_archive_before_delete).to be(true)
    expect(existing.notification_retention_days).to eq(0)

    AppSetting.delete_all
    fresh = AppSetting.create!
    described_class::POLICIES.each_value do |column, _unit, default, archive_column|
      expect(fresh.public_send(column)).to eq(default), "expected #{column} to default to #{default}"
      expect(fresh.public_send(archive_column)).to be(false) if archive_column
    end
  ensure
    migration.migrate(:up) unless connection.table_exists?(:retention_policy_settings)
    reset_app_setting_columns
  end

  def reset_app_setting_columns
    connection.schema_cache.clear!
    AppSetting.reset_column_information
  end
end
