module Api
  module V1
    module App
      module Admin
        class LocalBackupsController < BaseController
          def index
            render json: {
              configured: true,
              root: LocalBackups::StorageRoot.from_env.path.to_s,
              backups: LocalBackups::Backup.where(state: "completed").order(completed_at: :desc).map { |backup| serialize(backup) },
              invalid_artifacts: []
            }
          rescue LocalBackups::StorageRoot::Error => e
            render json: { configured: false, error: e.message, backups: [], invalid_artifacts: [] }
          end

          private

          def serialize(backup)
            backup.slice(:uuid, :state, :artifact_path, :manifest_version, :database_adapter, :logical_bytes,
              :stored_bytes, :blob_count, :checksum_algorithm, :checksum, :verification_state,
              :source_application_version, :completed_at, :validated_at)
          end
        end
      end
    end
  end
end
