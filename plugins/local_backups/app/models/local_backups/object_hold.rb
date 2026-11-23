module LocalBackups
  class ObjectHold < Syrus::Host::Record
    self.table_name = "local_backups_object_holds"

    belongs_to :backup, class_name: "LocalBackups::Backup", inverse_of: :object_holds

    validates :active_storage_blob_id, :storage_key, presence: true
    validates :active_storage_blob_id, uniqueness: { scope: :backup_id }

    def self.held?(blob_id)
      where(active_storage_blob_id: blob_id).exists?
    end
  end
end
