module Api
  module V1
    module App
      module Admin
        class LocalBackupsController < Syrus::Host::AppAdminController
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
            backup.with_lock do
              raise ArgumentError, "only a completed backup can be pinned" unless backup.state == "completed"
              backup.update!(pinned: true)
            end
            render json: { backup: backup_payload(backup) }
          rescue ArgumentError => e
            render_error("backup_not_completed", e.message, status: :unprocessable_entity)
          end

          def unpin
            backup = find_backup
            backup.with_lock { backup.update!(pinned: false) }
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

          def download
            backup = find_backup
            archive = LocalBackups::ArchiveStream.new
            tempfile = archive.open(backup)
            total = tempfile.size
            offset, length, status = download_range(total)
            AdminAction.log!(user: current_user, action: "local_backup_downloaded", params: {
              backup_uuid: backup.uuid, range_start: offset, range_length: length, archive_bytes: total
            })
            response.headers["Accept-Ranges"] = "bytes"
            response.headers["Cache-Control"] = "no-store"
            response.headers["Content-Type"] = "application/x-tar"
            response.headers["Content-Disposition"] = %(attachment; filename="syrus-backup-#{backup.uuid}.tar")
            response.headers["Content-Length"] = length.to_s
            response.headers["Content-Range"] = "bytes #{offset}-#{offset + length - 1}/#{total}" if status == :partial_content
            self.status = status
            self.response_body = archive.body(tempfile, offset:, length:)
          rescue RangeError
            tempfile&.close!
            response.headers["Content-Range"] = "bytes */#{total}"
            head :range_not_satisfiable
          end

          private

          def find_backup
            LocalBackups::Backup.find_by!(uuid: params[:id])
          end

          def download_range(total)
            header = request.headers["HTTP_RANGE"]
            return [0, total, :ok] if header.blank?

            match = /\Abytes=(\d*)-(\d*)\z/.match(header)
            raise RangeError unless match && (match[1].present? || match[2].present?)
            if match[1].blank?
              length = [match[2].to_i, total].min
              raise RangeError unless length.positive?
              return [total - length, length, :partial_content]
            end
            first = match[1].to_i
            last = match[2].present? ? [match[2].to_i, total - 1].min : total - 1
            raise RangeError if first >= total || last < first
            [first, last - first + 1, :partial_content]
          end

          def root_payload(root)
            usage = Syrus::Host::DiskUsage.read(root.path)
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
