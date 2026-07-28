module BugReports
  class GithubIssueCreator
    Result = Struct.new(:issue_url, :error_code, :error_message, keyword_init: true) do
      def success? = issue_url.present? && error_code.nil?
    end

    def initialize(user:)
      @user = user
    end

    def call(title:, description:)
      if user.github_token.blank?
        return Result.new(
          error_code: "github_token_required",
          error_message: "Connect a GitHub token before filing a report."
        )
      end

      title = title.to_s.strip.presence || "In-app bug report"
      body = description.to_s.strip

      issue = GithubClient.for_user(user).create_issue(
        AppSetting.report_issue_repo_slug,
        title: title,
        body: body
      )

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
