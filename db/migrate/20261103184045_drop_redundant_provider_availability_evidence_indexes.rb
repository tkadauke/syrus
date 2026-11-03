# provider_availability_evidences carried thirteen indexes. Two of them were
# dead weight on every insert, and this table is written on each provider
# interaction:
#
#   - idx_provider_evidence_status_observed duplicated
#     idx_provider_evidence_provider_status_observed exactly, same three
#     columns in the same order.
#   - idx_provider_evidence_user_provider_status_observed is the leftmost
#     prefix of idx_provider_evidence_user_provider_status_recent, so every
#     query it could serve is already served by the longer one.
#
# The single-column user_id index is also a prefix of five composites, but it
# is left alone: a bare FK-shaped index is cheap insurance if a foreign key is
# ever added, and removing it buys far less than these two.
class DropRedundantProviderAvailabilityEvidenceIndexes < ActiveRecord::Migration[8.1]
  REDUNDANT = %w[
    idx_provider_evidence_status_observed
    idx_provider_evidence_user_provider_status_observed
  ].freeze

  def up
    REDUNDANT.each do |name|
      remove_index :provider_availability_evidences, name: name if index_exists?(:provider_availability_evidences, nil, name: name)
    end
  end

  def down
    unless index_exists?(:provider_availability_evidences, nil, name: "idx_provider_evidence_status_observed")
      add_index :provider_availability_evidences, %i[provider status observed_at], name: "idx_provider_evidence_status_observed"
    end
    unless index_exists?(:provider_availability_evidences, nil, name: "idx_provider_evidence_user_provider_status_observed")
      add_index :provider_availability_evidences, %i[user_id provider status observed_at], name: "idx_provider_evidence_user_provider_status_observed"
    end
  end
end
