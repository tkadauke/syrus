class ChatMediaAttacher
  Result = Struct.new(:attached, :skipped, keyword_init: true) do
    def any_skipped?
      skipped.any?
    end
  end

  def initialize(chat_session:, job:)
    @chat_session = chat_session
    @job = job
  end

  def attach!(media_refs)
    attached = []
    skipped = []

    Array(media_refs).each do |ref|
      if job.job_attachments.count >= Document::MAX_ATTACHMENTS_PER_JOB
        skipped << { ref: ref, reason: "attachment limit reached (#{Document::MAX_ATTACHMENTS_PER_JOB} per job)" }
        Rails.logger.info("[ChatMediaAttacher] skipped media #{ref} for #{job.slug}: attachment limit reached")
        next
      end

      documents = Array(attach_single_media_ref(ref))
      if documents.any?
        attached.concat(documents)
      else
        skipped << { ref: ref, reason: "not found or could not be attached" }
      end
    end

    Result.new(attached: attached, skipped: skipped)
  end

  private

  attr_reader :chat_session, :job

  def attach_single_media_ref(ref)
    return nil unless ChatMediaRef.valid?(ref)

    kind, id = ChatMediaRef.split(ref)

    case kind
    when "snapshot"
      attach_snapshot(ref, id)
    when "chat_image"
      attach_chat_image(ref, id)
    when "preview_panel_version"
      attach_preview_panel_version(ref, id)
    end
  rescue StandardError => e
    Rails.logger.warn("[ChatMediaAttacher] skipped media #{ref} for #{job.slug}: #{e.class}: #{e.message}")
    nil
  end

  def attach_snapshot(ref, id)
    snapshot = chat_session.whiteboard_snapshots.find_by(id: id)
    return nil unless snapshot

    job.job_attachments.create!(
      kind: "pending_snapshot",
      title: snapshot.name.presence || "Whiteboard Snapshot",
      content_cache: snapshot.scene_json.to_json,
      source_url: ref
    )
  end

  def attach_chat_image(ref, id)
    document = chat_session.attached_repository_documents.find_by(id: id)
    return nil unless document&.file&.attached?

    new_doc = job.job_attachments.build(
      kind: "file",
      title: document.title,
      filename: document.filename,
      content_type: document.content_type,
      byte_size: document.byte_size,
      source_url: ref
    )
    new_doc.file.attach(document.file.blob)
    new_doc.save!
    new_doc
  end

  # Scoped through chat_session.preview_panels so a chat can only pull
  # files from a version it actually built, not any PreviewPanelVersion
  # id in the system.
  def attach_preview_panel_version(ref, id)
    version = PreviewPanelVersion.where(preview_panel: chat_session.preview_panels).find_by(id: id)
    return nil unless version

    file_attachments = version.files.to_a
    return nil if file_attachments.empty?

    remaining_capacity = Document::MAX_ATTACHMENTS_PER_JOB - job.job_attachments.count
    to_attach = file_attachments.first(remaining_capacity)
    omitted = file_attachments - to_attach

    documents = to_attach.map { |file_attachment| attach_preview_panel_file(ref, file_attachment) }
    note_omitted_preview_panel_files!(omitted) if omitted.any?
    documents
  end

  def attach_preview_panel_file(ref, file_attachment)
    filename = file_attachment.blob.filename.to_s
    new_doc = job.job_attachments.build(
      kind: "file",
      title: filename,
      filename: filename,
      content_type: file_attachment.blob.content_type,
      byte_size: file_attachment.blob.byte_size,
      source_url: "#{ref}##{file_attachment.blob.id}"
    )
    new_doc.file.attach(file_attachment.blob)
    new_doc.save!
    new_doc
  end

  # Rather than fail the whole attach when a version has more files than
  # Document::MAX_ATTACHMENTS_PER_JOB allows, attach what fits and record
  # which files were left out directly in the Job description so the
  # operator and implementing agent both see it.
  def note_omitted_preview_panel_files!(omitted_attachments)
    names = omitted_attachments.map { |attachment| attachment.blob.filename.to_s }
    note = "\n\n_Note: #{names.size} preview panel mockup file(s) were not attached because this Job " \
           "already has #{Document::MAX_ATTACHMENTS_PER_JOB} attachments (the per-Job limit): " \
           "#{names.join(', ')}._"
    job.update!(issue_body: "#{job.issue_body}#{note}")
  end
end
