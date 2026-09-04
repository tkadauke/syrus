module PreviewTools
  # The "preview_panel_version:<id>" media kind. A version can carry several
  # files, so this is the source that returns more than one Document.
  module MediaSource
    include Syrus::Plugin::ChatMediaSource

    def self.chat_media_kind = "preview_panel_version"

    # Scoped through chat_session.preview_panels so a chat can only pull files
    # from a version it actually built, not any PreviewPanelVersion id in the
    # system.
    def self.versions_for(chat_session)
      PreviewPanelVersion.where(preview_panel: chat_session.preview_panels)
    end

    def self.chat_media_exists?(chat_session:, id:)
      versions_for(chat_session).exists?(id)
    end

    def self.attach_chat_media(chat_session:, job:, ref:, id:)
      version = versions_for(chat_session).find_by(id: id)
      return nil unless version

      file_attachments = version.files.to_a
      return nil if file_attachments.empty?

      remaining_capacity = Document::MAX_ATTACHMENTS_PER_JOB - job.job_attachments.count
      to_attach = file_attachments.first(remaining_capacity)
      omitted = file_attachments - to_attach

      documents = to_attach.map { |file_attachment| attach_file(job, ref, file_attachment) }
      note_omitted!(job, omitted) if omitted.any?
      documents
    end

    def self.attach_file(job, ref, file_attachment)
      filename = file_attachment.blob.filename.to_s
      attachment = job.job_attachments.build(
        kind: "file",
        title: filename,
        filename: filename,
        content_type: file_attachment.blob.content_type,
        byte_size: file_attachment.blob.byte_size,
        source_url: "#{ref}##{file_attachment.blob.id}"
      )
      attachment.file.attach(file_attachment.blob)
      attachment.save!
      attachment
    end

    def self.note_omitted!(job, omitted_attachments)
      names = omitted_attachments.map { |attachment| attachment.blob.filename.to_s }
      note = "\n\n_Note: #{names.size} preview panel mockup file(s) were not attached because this Job " \
             "already has #{Document::MAX_ATTACHMENTS_PER_JOB} attachments (the per-Job limit): " \
             "#{names.join(', ')}._"
      job.update!(issue_body: "#{job.issue_body}#{note}")
    end
  end
end
