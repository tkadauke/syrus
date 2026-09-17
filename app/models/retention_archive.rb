# A serialized, archived batch of rows pruned from one retention-managed
# table (see RetentionPolicyRegistry) before their deletion from
# MySQL/SQLite. v1 is download-only: archives are kept forever and there is
# no automated restore path back into the live table.
class RetentionArchive < ApplicationRecord
  has_one_attached :archive_file, service: Rails.application.config.retention_archive_storage_service

  validates :retention_key, presence: true, inclusion: { in: ->(_record) { RetentionPolicyRegistry.definitions.map { |definition| definition.key.to_s } } }
  validates :pruned_before, presence: true
  validates :row_count, :byte_size, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :newest_first, -> { order(pruned_before: :desc, id: :desc) }
  scope :for_retention_key, ->(key) { where(retention_key: key) }
end
