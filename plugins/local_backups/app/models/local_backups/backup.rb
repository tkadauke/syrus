module LocalBackups
  class Backup < Syrus::Host::Record
    self.table_name = "local_backups_backups"

    STATES = %w[pending snapshotting exporting_objects validating completed failed deleting deleted].freeze

    has_many :replications, class_name: "LocalBackups::Replication", dependent: :destroy, inverse_of: :backup
    has_many :object_holds, class_name: "LocalBackups::ObjectHold", dependent: :destroy, inverse_of: :backup

    validates :uuid, presence: true, uniqueness: true
    validates :state, inclusion: { in: STATES }
    validates :artifact_relative_path, :manifest_version, presence: true
    validates :logical_bytes, :stored_bytes, :blob_count, numericality: { greater_than_or_equal_to: 0 }
  end
end
