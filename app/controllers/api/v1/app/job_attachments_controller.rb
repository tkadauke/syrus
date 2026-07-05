module Api
  module V1
    module App
      class JobAttachmentsController < BaseController
        def create
          job = find_job
          created, errors = create_attachments(job)

          if created.any?
            broadcast_attachment_change(job.reload)
            render json: attachments_payload(
              job,
              message: attachment_create_message(created, errors),
              created_attachment_ids: created.map(&:id),
              errors: errors
            )
          else
            render_error(
              "validation_failed",
              errors.presence&.to_sentence || "Choose a file or enter a Google Doc URL.",
              status: :unprocessable_content
            )
          end
        end

        def destroy
          job = find_job
          attachment = job.job_attachments.find(params[:id])
          attachment.destroy!
          broadcast_attachment_change(job.reload)

          render json: attachments_payload(job, message: "Attachment removed.")
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs, params[:job_id])
        end

        def create_attachments(job)
          created = []
          errors = []

          uploaded_files.each do |file|
            attachment = job.job_attachments.build(attachment_type: "uploaded_file")
            attachment.file.attach(file)
            if attachment.save
              created << attachment
            else
              errors.concat(attachment.errors.full_messages)
            end
          end

          if google_doc_url.present?
            attachment = job.job_attachments.build(
              attachment_type: "google_doc_link",
              google_doc_url: google_doc_url
            )
            if attachment.save
              created << attachment
            else
              errors.concat(attachment.errors.full_messages)
            end
          end

          [ created, errors ]
        end

        def uploaded_files
          Array(params.dig(:job_attachment, :files)).compact_blank
        end

        def google_doc_url
          params.dig(:job_attachment, :google_doc_url).to_s.strip
        end

        def attachment_create_message(created, errors)
          return "Some attachments could not be added: #{errors.to_sentence}" if errors.any?

          created.one? ? "Attachment added." : "Attachments added."
        end

        def attachments_payload(job, message:, created_attachment_ids: [], errors: [])
          attachments = job.job_attachments.includes(file_attachment: :blob)

          {
            message: message,
            errors: errors,
            created_attachment_ids: created_attachment_ids,
            job: {
              id: job.id,
              attachments_count: attachments.size,
              max_attachments: Document::MAX_ATTACHMENTS_PER_JOB
            },
            attachments: attachments.map { |attachment| attachment_json(job, attachment) },
            paths: {
              app_attachments_path: "/api/v1/app/jobs/#{job.id}/attachments",
              job_path: job_path(job, tab: "attachments")
            }
          }
        end

        def attachment_json(job, attachment)
          {
            id: attachment.id,
            kind: attachment.kind,
            attachment_type: attachment.attachment_type,
            title: attachment.title,
            display_name: attachment.display_name,
            filename: attachment.filename,
            content_type: attachment.content_type,
            byte_size: attachment.byte_size,
            google_doc_url: attachment.google_doc_url,
            app_delete_path: "/api/v1/app/jobs/#{job.id}/attachments/#{attachment.id}"
          }
        end

        def broadcast_attachment_change(job)
          AppEvents.broadcast(
            user: Current.user,
            type: "updated",
            resource: "job",
            id: job.id,
            changed: [ "attachments" ],
            payload: { "attachments_count" => job.job_attachments.size }
          )
        end
      end
    end
  end
end
