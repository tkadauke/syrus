module Api
  module V1
    module App
      class ReportIssueController < BaseController
        def create
          if Current.user.github_token.blank?
            render_error(
              "github_token_required",
              "Connect a GitHub token before filing a report.",
              status: :unprocessable_content
            )
            return
          end

          title = params.require(:title).to_s.strip
          body = params[:body].to_s
          if title.blank?
            render_error("validation_failed", "Title is required.", status: :unprocessable_content)
            return
          end

          issue = GithubClient.for_user(Current.user).create_issue(
            AppSetting.report_issue_repo_slug,
            title: title,
            body: body
          )

          render json: { issue_url: issue.html_url }, status: :created
        rescue Octokit::Error => e
          render_error("github_error", "GitHub issue could not be filed: #{e.message}", status: :bad_gateway)
        end
      end
    end
  end
end
