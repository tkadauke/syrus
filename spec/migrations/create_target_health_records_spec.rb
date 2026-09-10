require "rails_helper"

RSpec.describe "target_health_records schema" do
  let(:connection) { ActiveRecord::Base.connection }

  it "has the lookup indexes needed for reusable target health" do
    indexes = connection.indexes(:target_health_records)

    identity = indexes.find { |index| index.name == "idx_target_health_records_identity" }
    expect(identity).to be_present
    expect(identity.unique).to eq(true)
    expect(identity.columns).to eq(%w[
      repository_id
      target_label
      commit_sha
      input_fingerprint
      command_fingerprint
      environment_fingerprint
    ])

    expect(indexes.map(&:name)).to include(
      "idx_target_health_records_repo_target_sha",
      "idx_target_health_records_project_status"
    )
  end
end
