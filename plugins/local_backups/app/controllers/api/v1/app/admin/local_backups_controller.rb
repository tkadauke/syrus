module Api
  module V1
    module App
      module Admin
        class LocalBackupsController < BaseController
          def index
            root = LocalBackups::StorageRoot.new
            scan = LocalBackups::InventoryScanner.new(root:).call
            render json: {
              root: root_payload(root),
              scan: { discovered: scan.discovered, invalid: scan.invalid },
              backups: LocalBackups::Backup.where(state: "completed").order(completed_at: :desc).map { |backup| backup_payload(backup) }
            }
          rescue LocalBackups::StorageRoot::Invalid => e
            render json: { root: { configured: false, error: e.message }, scan: { discovered: 0, invalid: [] }, backups: [] }
          end

          private

          def root_payload(root)
            { configured: true, path: root.path.to_s }
          end

          def backup_payload(backup)
            backup.as_json(only: %i[uuid reason database_adapter logical_bytes stored_bytes blob_count completed_at
              validated_at verification_state source_application_version artifact_checksum checksum_algorithm
              encryption_key_fingerprint])
          end
        end
      end
    end
  end
end
