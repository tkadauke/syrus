require "rails_helper"

RSpec.describe "AddTriggerKindIdIndexToRuns", :ci_only do
  it "indexes runs by trigger_kind and id for the admin Run list" do
    expect(
      ActiveRecord::Base.connection.index_exists?(:runs, [ :trigger_kind, :id ], name: "idx_runs_trigger_kind_id")
    ).to eq(true)
  end
end
