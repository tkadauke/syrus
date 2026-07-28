module BugReports
  class Router
    Result = Struct.new(:job, :issue_url, :error_code, :error_message, :mode, keyword_init: true) do
      def success? = error_code.nil? && error_message.nil?
    end

    def initialize(user:)
      @user = user
    end

    def self.mode_for(user:)
      return nil unless user

      new(user: user).mode
    end

    def mode
      system_repo || user_fork_repo ? :direct_job : :github_issue
    end

    def call(title:, description:, screenshot: nil, attachments: [])
      if (repo = system_repo || user_fork_repo)
        route_to_creator(repo, title: title, description: description, screenshot: screenshot)
      else
        route_to_github_issue(title: title, description: description, screenshot: screenshot, attachments: attachments)
      end
    end

    private

    attr_reader :user

    def target_owner
      AppSetting.report_issue_repo_slug.split("/", 2).first
    end

    def target_name
      AppSetting.report_issue_repo_slug.split("/", 2).last
    end

    def system_repo
      Repository.active.find_by(owner: target_owner, name: target_name)
    end

    def user_fork_repo
      user.repositories.active.find_by(upstream_owner: target_owner, upstream_name: target_name)
    end

    def route_to_creator(repository, title:, description:, screenshot:)
      # Extra attachments are not forwarded — Creator stores the screenshot as a
      # job_attachment; inline embedding is only needed on the GitHub-issue path.
      result = BugReports::Creator.new(user: user, repository: repository).call(
        title: title, description: description, screenshot: screenshot
      )
      if result.success?
        Result.new(job: result.job, mode: :direct_job)
      else
        Result.new(error_message: result.error, mode: :direct_job)
      end
    end

    def route_to_github_issue(title:, description:, screenshot: nil, attachments: [])
      result = BugReports::GithubIssueCreator.new(user: user).call(
        title: title, description: description, screenshot: screenshot, attachments: attachments
      )
      if result.success?
        Result.new(issue_url: result.issue_url, mode: :github_issue)
      else
        Result.new(error_code: result.error_code, error_message: result.error_message, mode: :github_issue)
      end
    end
  end
end
