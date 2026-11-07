module Api
  module V1
    module App
      class ChatAttachmentsController < BaseController
        def create
          chat = find_chat
          upload = params.require(:file)
          bytes = upload.read
          policy = ChatAttachmentPolicy.check(filename: upload.original_filename, mime_type: upload.content_type)
          return render_error("validation_failed", "Unsupported attachment type.", status: :unprocessable_content) unless policy.accepted?
          return render_error("validation_failed", I18n.t("server.errors.chat_attachments.file_too_large"), status: :unprocessable_content) if bytes.bytesize > ChatMessageParams::CHAT_ATTACHMENT_MAX_BYTES
          if chat.chat_file_attachments.sum(:byte_size) + bytes.bytesize > ChatMessageParams::CHAT_ATTACHMENT_TOTAL_MAX_BYTES
            return render_error("validation_failed", I18n.t("server.errors.chat_attachments.total_too_large"), status: :unprocessable_content)
          end
          if policy.text? && !ChatAttachmentPolicy.valid_text?(bytes)
            return render_error("validation_failed", I18n.t("server.errors.chat_attachments.invalid_utf8", name: upload.original_filename), status: :unprocessable_content)
          end

          attachment = chat.chat_file_attachments.build(name: upload.original_filename, mime_type: policy.mime_type, byte_size: bytes.bytesize, checksum: "pending")
          attachment.file.attach(io: StringIO.new(bytes), filename: ChatAttachmentPolicy.sanitize_filename(upload.original_filename), content_type: policy.mime_type)
          attachment.save!
          render json: attachment_json(attachment), status: :created
        end

        def show
          attachment = find_chat.chat_file_attachments.find(params[:id])
          raise ActiveRecord::RecordNotFound, "Attachment file not found" unless attachment.file.attached?
          send_secure_file attachment.file.download, filename: attachment.name, type: attachment.mime_type
        end

        private

        def find_chat
          invocation_scoped_chat_scope(Current.user.accessible_chat_sessions).active.find(params[:chat_id])
        end

        def attachment_json(attachment)
          { id: attachment.id, name: attachment.name, mime_type: attachment.mime_type, size: attachment.byte_size,
            url: "/api/v1/app/chats/#{attachment.chat_session_id}/attachments/#{attachment.id}/file" }
        end
      end
    end
  end
end
