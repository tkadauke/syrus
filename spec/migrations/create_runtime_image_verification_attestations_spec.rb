require "rails_helper"
require Rails.root.join("db/migrate/20261128025957_create_runtime_image_verification_attestations")

RSpec.describe CreateRuntimeImageVerificationAttestations do
  it "creates digest-bound attestations and unique revocation triggers idempotently" do
    migration = described_class.new
    expect { migration.migrate(:up) }.not_to raise_error

    connection = ActiveRecord::Base.connection
    expect(connection.columns(:runtime_image_verification_attestations).map(&:name)).to include(
      "image_digest", "policy_digest", "evidence_digest", "safe_summary", "expires_at", "exact_evidence_purged_at"
    )
    expect(connection.indexes(:runtime_image_revocation_candidates).find { |index| index.name == "idx_ri_revocation_trigger" }.unique).to be(true)
  end
end
