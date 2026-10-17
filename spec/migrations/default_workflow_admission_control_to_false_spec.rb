require "rails_helper"
require Rails.root.join("db/migrate/20261017041659_default_workflow_admission_control_to_false")

RSpec.describe DefaultWorkflowAdmissionControlToFalse, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.up
    ActiveRecord::Base.connection.schema_cache.clear!
    AppSetting.reset_column_information
  end

  it "defaults fresh rows to false without rewriting an existing true value" do
    migration.down
    ActiveRecord::Base.connection.schema_cache.clear!
    AppSetting.reset_column_information
    AppSetting.delete_all
    existing = AppSetting.create!(
      singleton_key: AppSetting::SINGLETON_KEY,
      workflow_admission_control_enabled: true
    )

    expect { migration.up }.not_to change { existing.reload.workflow_admission_control_enabled }
    ActiveRecord::Base.connection.schema_cache.clear!
    AppSetting.reset_column_information

    expect(AppSetting.new.workflow_admission_control_enabled).to be(false)
  end

  it "is idempotent" do
    expect {
      migration.up
      migration.up
    }.not_to raise_error
  end
end
