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

          def create
            LocalBackups::CreateJob.perform_later(reason: "manual")
            render json: { queued: true }, status: :accepted
          end

          def validate
            backup = find_backup
            LocalBackups::Validator.new.call(backup)
            render json: { backup: backup_payload(backup.reload) }
          rescue LocalBackups::Validator::Invalid => e
            render_error("backup_invalid", e.message, status: :unprocessable_entity)
          end

          def pin
            backup = find_backup
            backup.update!(pinned: true)
            render json: { backup: backup_payload(backup) }
          end

          def unpin
            backup = find_backup
            backup.update!(pinned: false)
            render json: { backup: backup_payload(backup) }
          end

          def destroy
            backup = find_backup
            raise ArgumentError, "backup is protected from deletion" unless LocalBackups::Retention.new.eligible?(backup)

            LocalBackups::DeleteJob.perform_later(backup.id)
            head :accepted
          rescue ArgumentError => e
            render_error("backup_protected", e.message, status: :unprocessable_entity)
          end

          private

          def find_backup
            LocalBackups::Backup.find_by!(uuid: params[:id])
          end

          def root_payload(root)
            usage = DataRootDiskUsage.read(root.path)
            { configured: true, path: root.path.to_s, available_bytes: usage&.available_bytes }
          end

          def backup_payload(backup)
            backup.as_json(only: %i[uuid reason database_adapter logical_bytes stored_bytes blob_count completed_at
              validated_at verification_state source_application_version artifact_checksum checksum_algorithm
              encryption_key_fingerprint pinned state])
          end
        end
      end
    end
  end
end
