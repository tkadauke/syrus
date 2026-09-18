module BugReports
  class Creator
    include BugReports::ContextFormatter
    Result = Struct.new(:job, :error, keyword_init: true) do
      def success?
        job.present? && error.blank?
      end
    end

    def initialize(user:, repository:)
      @user = user
      @repository = repository
    end

    def call(title:, description:, screenshot:, attachments: [], context: nil)
      title = title.to_s.strip.presence || "In-app bug report"
      description = description.to_s.strip
      prompt_text = [ title, description ].reject(&:blank?).join("\n\n") + format_context_markdown(context)

      if screenshot.present? && screenshot.content_type != "image/png"
        return failure("Screenshot must be a PNG.")
      end

      extra = Array(attachments).select(&:present?)
      total = (screenshot.present? ? 1 : 0) + extra.size
      if total > Document::MAX_ATTACHMENTS_PER_JOB
        return failure("Too many attachments. Bug reports can have at most #{Document::MAX_ATTACHMENTS_PER_JOB} files.")
      end

      uploads = [ screenshot, *extra ].select(&:present?)
      result = ::DirectJobs::Creator.new(user: user).call(
        repository: repository,
        prompt_text: prompt_text,
        title: title,
        attachments: uploads.map { |upload| build_attachment(upload) }
      )

      return failure(result.error) unless result.success?

      Result.new(job: result.job)
    end

    private

    attr_reader :user, :repository

    def failure(error)
      Result.new(error: error)
    end

    def build_attachment(upload)
      ::DirectJobs::Creator::Attachment.new(
        source_url: "bug-report://#{SecureRandom.uuid}",
        filename: upload.original_filename.presence || "attachment",
        content_type: upload.content_type.presence || "application/octet-stream",
        body: upload.read
      )
    end
  end
end
