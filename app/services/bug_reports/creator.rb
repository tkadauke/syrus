require "stringio"

module BugReports
  class Creator
    TARGET_NAME = "syrus".freeze

    Result = Struct.new(:job, :error, keyword_init: true) do
      def success?
        job.present? && error.blank?
      end
    end

    def initialize(user:)
      @user = user
    end

    def call(title:, description:, screenshot:)
      repository = Repository.active.find_by(owner: target_owner, name: TARGET_NAME)
      return failure("Bug report repository #{target_owner}/#{TARGET_NAME} is not configured.") unless repository

      title = title.to_s.strip.presence || "In-app bug report"
      description = description.to_s.strip
      prompt_text = [ title, description ].reject(&:blank?).join("\n\n")

      if screenshot.present? && screenshot.content_type != "image/png"
        return failure("Screenshot must be a PNG.")
      end

      job = nil
      ActiveRecord::Base.transaction do
        job = user.jobs.create!(
          repository: repository,
          kind: "direct",
          issue_number: nil,
          issue_title: title,
          issue_body: prompt_text,
          agent_provider: repository.effective_agent_provider,
          priority: "medium"
        )

        # advance_after_triage's after-callback creates the initial
        # workflow + starts it for direct Jobs (Job#create_initial_run_if_needed).
        job.advance_after_triage! if job.may_advance_after_triage?

        attach_screenshot!(job, screenshot) if screenshot.present?
      end

      Result.new(job: job)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :user

    def target_owner
      ENV.fetch("SYRUS_BUG_REPORT_OWNER")
    end

    def failure(error)
      Result.new(error: error)
    end

    def attach_screenshot!(job, upload)
      body = upload.read
      filename = upload.original_filename.presence || "bug-report-screenshot.png"
      content_type = upload.content_type.presence || "image/png"

      attachment = job.job_attachments.build(
        source_url: "bug-report://#{SecureRandom.uuid}",
        filename: filename,
        content_type: content_type,
        byte_size: body.bytesize
      )
      attachment.file.attach(
        io: StringIO.new(body),
        filename: filename,
        content_type: content_type,
        identify: false
      )
      attachment.save!
    end
  end
end
