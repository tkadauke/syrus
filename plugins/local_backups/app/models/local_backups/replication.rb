module LocalBackups
  class Replication < ApplicationRecord
    self.table_name = "local_backups_replications"

    belongs_to :backup, class_name: "LocalBackups::Backup", inverse_of: :replications
    STATES = %w[pending uploading uploaded verified failed deleting deleted].freeze
    validates :destination_key, presence: true, uniqueness: { scope: :backup_id }
    validates :state, inclusion: { in: STATES }
  end
end
