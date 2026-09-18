require "base64"

module SyrusDev
  # Backs the Tool Card Catalog's "Create Job" shortcut: the same
  # screenshot + free-text prompt the "Discuss this card" dialog already
  # collects, but landed directly as a direct Job instead of a chat that
  # still has to be pushed through triage. Targets whatever repository
  # ::BugReports::Router already resolves for "file this about Syrus
  # itself" (the configured report_issue_repo_slug, or the operator's own
  # fork of it) -- the Tool Card Catalog only exists to develop Syrus, so
  # there is no separate repository picker to ask the operator for.
  #
  # The actual Job-creation/triage-advance/attachment transaction is shared
  # with BugReports::Creator via ::DirectJobs::Creator; this class only
  # owns what's specific to a Tool Card Catalog screenshot (it arrives as a
  # base64 JSON payload, not an uploaded file, so it needs its own
  # decode/mime validation).
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

      attachment, screenshot_error = normalize_screenshot(screenshot)
      return failure(screenshot_error) if screenshot_error

      result = ::DirectJobs::Creator.new(user: user).call(
        repository: repository,
        prompt_text: prompt_text,
        attachments: attachment ? [ attachment ] : []
      )

      return failure(result.error) unless result.success?

      Result.new(job: result.job)
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

      attachment = ::DirectJobs::Creator::Attachment.new(
        source_url: "tool-card-catalog://#{SecureRandom.uuid}",
        filename: name,
        content_type: mime_type,
        body: Base64.decode64(data)
      )
      [ attachment, nil ]
    end
  end
end
