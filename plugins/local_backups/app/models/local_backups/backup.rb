module LocalBackups
  class Backup < ApplicationRecord
    self.table_name = "local_backups_backups"

    has_many :replications, class_name: "LocalBackups::Replication", dependent: :destroy, inverse_of: :backup
    STATES = %w[pending snapshotting exporting_objects validating completed failed deleting deleted].freeze
    VERIFICATION_STATES = %w[unverified valid invalid].freeze

    after_initialize { self.encryption_fingerprints ||= {} }
    validates :uuid, :artifact_path, :manifest_version, presence: true
    validates :uuid, uniqueness: true
    validates :state, inclusion: { in: STATES }
    validates :verification_state, inclusion: { in: VERIFICATION_STATES }
    validates :logical_bytes, :stored_bytes, :blob_count, numericality: { greater_than_or_equal_to: 0 }
  end
end
