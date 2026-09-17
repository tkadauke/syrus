module Api
  module V1
    module App
      module Admin
        # Read-only history of RetentionArchive sweeps for one archivable
        # RetentionPolicyRegistry key. v1 is download-only (see
        # RetentionArchiver/RetentionArchive) -- there is no restore action
        # here, only #index and #download.
        class RetentionArchivesController < BaseController
          include Paginatable

          PER_PAGE = 20

          def index
            render json: payload
          end

          # Hands off to Active Storage's own signed blob redirect rather than
          # streaming the (potentially large) archive through this process --
          # this action's only job is the admin-auth check `require_admin`
          # already applies before the request ever reaches here.
          def download
            archive = RetentionArchive.find(params[:id])
            raise ActiveRecord::RecordNotFound, "Archive file not found" unless archive.archive_file.attached?

            redirect_to rails_blob_path(archive.archive_file, disposition: "attachment")
          end

          private

          def payload
            relation = RetentionArchive.for_retention_key(definition.key.to_s).newest_first.with_attached_archive_file
            total = relation.count
            page = page_param
            total_pages = total.zero? ? 0 : (total.to_f / PER_PAGE).ceil
            archives = relation.offset((page - 1) * PER_PAGE).limit(PER_PAGE)

            {
              retention_key: definition.key.to_s,
              archives: archives.map { |archive| archive_json(archive) },
              pagination: {
                page: page,
                per_page: PER_PAGE,
                total: total,
                total_pages: total_pages,
                first_item: total.zero? ? 0 : (page - 1) * PER_PAGE + 1,
                last_item: [ page * PER_PAGE, total ].min
              }
            }
          end

          def archive_json(archive)
            attached = archive.archive_file.attached?
            {
              id: archive.id,
              pruned_before: archive.pruned_before.iso8601,
              row_count: archive.row_count,
              byte_size: archive.byte_size,
              created_at: archive.created_at.iso8601,
              filename: attached ? archive.archive_file.filename.to_s : nil,
              download_path: attached ? download_api_v1_app_admin_retention_archive_path(archive) : nil
            }
          end

          def definition
            @definition ||= find_definition
          end

          def find_definition
            found = RetentionPolicyRegistry.fetch(params[:retention_key])
            raise ActiveRecord::RecordNotFound, "#{params[:retention_key]} is not archivable" unless found.archivable

            found
          rescue KeyError
            raise ActiveRecord::RecordNotFound, "Unknown retention key: #{params[:retention_key]}"
          end
        end
      end
    end
  end
end
