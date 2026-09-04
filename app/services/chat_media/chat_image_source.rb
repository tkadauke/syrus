module ChatMedia
  # Core's own media kind: an image already attached to the chat. Implemented
  # as a source like any plugin's so there is one code path rather than a
  # special case beside the registry lookup.
  module ChatImageSource
    include Syrus::Plugin::ChatMediaSource

    def self.chat_media_kind = "chat_image"

    def self.chat_media_exists?(chat_session:, id:)
      chat_session.attached_repository_documents.exists?(id)
    end

    def self.attach_chat_media(chat_session:, job:, ref:, id:)
      document = chat_session.attached_repository_documents.find_by(id: id)
      return nil unless document&.file&.attached?

      attachment = job.job_attachments.build(
        kind: "file",
        title: document.title,
        filename: document.filename,
        content_type: document.content_type,
        byte_size: document.byte_size,
        source_url: ref
      )
      attachment.file.attach(document.file.blob)
      attachment.save!
      attachment
    end

    def self.list_chat_media(chat_session:)
      chat_session.attached_repository_documents
                  .newest_first
                  .to_a
                  .select { |doc| doc.content_type.to_s.start_with?("image/") }
                  .map do |doc|
        {
          id: "chat_image:#{doc.id}",
          kind: "chat_image",
          filename: doc.filename,
          content_type: doc.content_type,
          file_path: "/api/v1/app/chats/#{chat_session.id}/media/chat_images/#{doc.id}/file"
        }
      end
    end
  end
end
