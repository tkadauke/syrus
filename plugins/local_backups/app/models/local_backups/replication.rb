module LocalBackups
  class Replication < Syrus::Host::Record
    self.table_name = "local_backups_replications"

    belongs_to :backup, class_name: "LocalBackups::Backup", inverse_of: :replications

    validates :destination_identity, :state, presence: true
    validates :destination_identity, uniqueness: { scope: :backup_id }
  end
end
