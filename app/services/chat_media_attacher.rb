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

      document = attach_single_media_ref(ref)
      if document
        attached << document
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
end
