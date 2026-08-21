require "rails_helper"
require Rails.root.join("db/migrate/20260821203829_make_merge_train_epic_optional_add_priority")

RSpec.describe MakeMergeTrainEpicOptionalAddPriority, :ci_only do
  it "is idempotent when run more than once" do
    migration = described_class.new

    expect {
      migration.up
      migration.up
    }.not_to raise_error

    connection = ActiveRecord::Base.connection
    expect(connection.column_exists?(:merge_trains, :priority)).to eq(true)
    expect(connection.columns(:merge_trains).find { |c| c.name == "epic_id" }.null).to eq(true)
  end
end
