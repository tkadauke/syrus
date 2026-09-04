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
    source = ChatMediaSources.for_kind(kind)
    return nil unless source

    source.attach_chat_media(chat_session: chat_session, job: job, ref: ref, id: id)
  rescue StandardError => e
    Rails.logger.warn("[ChatMediaAttacher] skipped media #{ref} for #{job.slug}: #{e.class}: #{e.message}")
    nil
  end
end
