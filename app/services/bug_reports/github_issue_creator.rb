module BugReports
  class GithubIssueCreator
    Result = Struct.new(:issue_url, :error_code, :error_message, keyword_init: true) do
      def success? = issue_url.present? && error_code.nil?
    end

    def initialize(user:)
      @user = user
    end

    def call(title:, description:, screenshot: nil, attachments: [])
      if user.github_token.blank?
        return Result.new(
          error_code: "github_token_required",
          error_message: "Connect a GitHub token before filing a report."
        )
      end

      title = title.to_s.strip.presence || "In-app bug report"
      repo_slug = AppSetting.report_issue_repo_slug
      issue_client = GithubClient.for_user(user)

      # Use the installation-backed client for uploads when available — it has
      # write access to the target repo, which create_contents requires.
      target_repo = Repository.active.find_by("LOWER(CONCAT(owner, '/', name)) = ?", repo_slug.downcase)
      upload_client = begin
        target_repo ? GithubClient.for(repository: target_repo, user: user) : issue_client
      rescue => e
        Rails.logger.warn("[BugReports::GithubIssueCreator] falling back to PAT for uploads: #{e.class}: #{e.message}")
        issue_client
      end

      body_parts = [ description.to_s.strip ]

      if screenshot.present?
        url = upload_client.upload_issue_asset(
          repo_slug,
          io: screenshot,
          content_type: screenshot.content_type.presence || "image/png",
          filename: screenshot.original_filename.presence || "screenshot.png"
        )
        body_parts << if url
          "![Screenshot](#{url})"
        else
          "_Attachment could not be uploaded automatically. Please attach it manually._"
        end
      end

      extra_attachments = Array(attachments).select(&:present?)
      if extra_attachments.any?
        lines = extra_attachments.map do |attachment|
          name = attachment.original_filename.presence || "attachment"
          url = upload_client.upload_issue_asset(
            repo_slug,
            io: attachment,
            content_type: attachment.content_type.presence || "application/octet-stream",
            filename: name
          )
          url ? "- [#{name}](#{url})" : "- _#{name} could not be uploaded automatically. Please attach it manually._"
        end
        body_parts << lines.join("\n")
      end

      body = body_parts.reject(&:blank?).join("\n\n")

      issue = issue_client.create_issue(repo_slug, title: title, body: body)
      Result.new(issue_url: issue.html_url)
    rescue Octokit::Error => e
      Result.new(
        error_code: "github_error",
        error_message: "GitHub issue could not be filed: #{e.message}"
      )
    end

    private

    attr_reader :user
  end
end
