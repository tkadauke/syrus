require "base64"
require "stringio"

module SyrusDev
  # Backs the Tool Card Catalog's "Create Job" shortcut: the same
  # screenshot + free-text prompt the "Discuss this card" dialog already
  # collects, but landed directly as a direct Job instead of a chat that
  # still has to be pushed through triage. Targets whatever repository
  # ::BugReports::Router already resolves for "file this about Syrus
  # itself" (the configured report_issue_repo_slug, or the operator's own
  # fork of it) -- the Tool Card Catalog only exists to develop Syrus, so
  # there is no separate repository picker to ask the operator for.
  class ToolCardJobCreator
    Result = Struct.new(:job, :error, keyword_init: true) do
      def success?
        job.present? && error.blank?
      end
    end

    ALLOWED_SCREENSHOT_MIME_TYPES = %w[image/png].freeze

    def initialize(user:)
      @user = user
    end

    def call(prompt:, screenshot: nil)
      prompt_text = prompt.to_s.strip
      return failure("Prompt can't be blank.") if prompt_text.blank?

      repository = target_repository
      return failure("Tool Card jobs are only available when this instance can file Syrus Jobs for itself.") unless repository

      screenshot_attrs, screenshot_error = normalize_screenshot(screenshot)
      return failure(screenshot_error) if screenshot_error

      job = nil
      ActiveRecord::Base.transaction do
        job = user.jobs.create!(
          repository: repository,
          kind: "direct",
          issue_number: nil,
          issue_title: GenerateJobTitleJob::PENDING_TITLE,
          title_pending: true,
          issue_body: prompt_text,
          agent_provider: repository.effective_agent_provider,
          priority: "medium"
        )

        job.advance_after_triage! if job.may_advance_after_triage?

        attach_screenshot!(job, screenshot_attrs) if screenshot_attrs
      end

      GenerateJobTitleJob.perform_later(job) if job.title_pending?

      Result.new(job: job)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :user

    def failure(error)
      Result.new(error: error)
    end

    def target_repository
      ::BugReports::Router.new(user: user).target_repository
    end

    def normalize_screenshot(screenshot)
      return [ nil, nil ] if screenshot.blank?

      attrs = screenshot.respond_to?(:to_unsafe_h) ? screenshot.to_unsafe_h : screenshot
      mime_type = (attrs["mime_type"] || attrs[:mime_type]).to_s
      data = (attrs["data"] || attrs[:data]).to_s
      name = (attrs["name"] || attrs[:name]).presence || "tool-card-screenshot.png"

      return [ nil, "Screenshot must be a PNG." ] unless ALLOWED_SCREENSHOT_MIME_TYPES.include?(mime_type)
      return [ nil, "Screenshot data is missing." ] if data.blank?

      [ { name: name, mime_type: mime_type, body: Base64.decode64(data) }, nil ]
    end

    def attach_screenshot!(job, attrs)
      attachment = job.job_attachments.build(
        source_url: "tool-card-catalog://#{SecureRandom.uuid}",
        filename: attrs[:name],
        content_type: attrs[:mime_type],
        byte_size: attrs[:body].bytesize
      )
      attachment.file.attach(
        io: StringIO.new(attrs[:body]),
        filename: attrs[:name],
        content_type: attrs[:mime_type],
        identify: false
      )
      attachment.save!
    end
  end
end
