module Api
  module V1
    module App
      # GitHub issue browsing and triage actions for the repository page.
      #
      # Lives in the github_source plugin: listing issues, commenting, closing,
      # and delegating are GitHub-specific operations, and an instance whose
      # work arrives from somewhere else has no use for them.
      class RepositoryIssuesController < BaseController
        include RepositoryTabsSerialization
        include RepositorySummarySerialization

        def issues
          return render_error("not_found", "GitHub issues are not available in simple mode.", status: :not_found) if AppSetting.simple?

          repository = find_repository
          render json: repository_issues_payload(repository, state: issue_state)
        end


        def comment_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          body = params[:comment_body].to_s.strip
          if body.blank?
            render_error("validation_failed", I18n.t("api.repositories.comment_blank"), status: :unprocessable_content)
            return
          end

          GithubClient.for(repository: repository, user: Current.user).add_issue_comment(
            repository.slug,
            issue_number,
            body,
            on_behalf_of: Current.user
          )

          render json: repository_issues_payload(repository, state: issue_state, message: I18n.t("api.repositories.comment_added", number: issue_number))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.comment_failed", error: e.message), status: :bad_gateway)
        end


        def close_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).close_issue(repository.slug, issue_number)

          render json: repository_issues_payload(repository, state: issue_state, message: I18n.t("api.repositories.issue_closed", number: issue_number))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.issue_close_failed", error: e.message), status: :bad_gateway)
        end


        def delegate_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).add_label_to_issue(repository.slug, issue_number, repository.trigger_label)

          render json: repository_issues_payload(repository, state: issue_state, message: I18n.t("api.repositories.issue_delegated", number: issue_number))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.issue_delegate_failed", error: e.message), status: :bad_gateway)
        end


        def bulk_issues
          repository = find_repository
          issue_numbers = selected_issue_numbers
          if issue_numbers.empty?
            render_error("validation_failed", I18n.t("api.repositories.select_issue"), status: :unprocessable_content)
            return
          end

          case params[:bulk_action]
          when "delegate"
            bulk_delegate_issues(repository, issue_numbers)
          when "close"
            bulk_close_issues(repository, issue_numbers)
          else
            render_error("validation_failed", I18n.t("api.repositories.choose_action"), status: :unprocessable_content)
          end
        end


        def repository_issues_payload(repository, state:, message: nil)
          issues = []
          error_message = nil
          begin
            issues = GithubClient.for(repository: repository, user: Current.user).list_all_issues(repository.slug, state: state).first(50)
          rescue ArgumentError
            error_message = I18n.t("api.repositories.no_github_token")
          rescue Octokit::Error => e
            error_message = I18n.t("api.repositories.github_error", error: e.message)
          end

          {
            message: message,
            error_message: error_message,
            repository: repository_detail_json(repository),
            tabs: repository_tabs_json(repository),
            state: state,
            issue_count: issues.size,
            issues: issues.map { |issue| issue_json(repository, issue) },
            state_paths: {
              open: repository_path(repository, tab: "github_issues", state: "open"),
              closed: repository_path(repository, tab: "github_issues", state: "closed")
            },
            paths: {
              github_issues_path: "https://github.com/#{repository.slug}/issues",
              app_comment_issue_path: "/api/v1/app/repositories/#{repository.id}/issues/comment",
              app_close_issue_path: "/api/v1/app/repositories/#{repository.id}/issues/close",
              app_delegate_issue_path: "/api/v1/app/repositories/#{repository.id}/issues/delegate",
              app_bulk_issues_path: "/api/v1/app/repositories/#{repository.id}/issues/bulk"
            }
          }
        end


        def issue_json(repository, issue)
          labels = Array(issue.labels)
          {
            number: issue.number,
            title: issue.title.to_s,
            state: issue.state.to_s,
            html_url: issue.html_url.to_s,
            body_excerpt: issue.body.to_s.gsub(/\r?\n/, " ").truncate(180),
            user_login: issue.user&.login,
            created_at: issue.created_at&.iso8601,
            labels: labels.map { |label| issue_label_json(label) },
            delegated: labels.any? { |label| label.name == repository.trigger_label }
          }
        end


        def issue_label_json(label)
          {
            name: label.name.to_s,
            color: label.color.to_s.presence || "6b7280"
          }
        end


        def issue_state
          params.fetch(:state, "open").presence_in(%w[open closed]) || "open"
        end


        def selected_issue_numbers
          Array(params[:issue_numbers]).filter_map do |number|
            Integer(number, exception: false)
          end.select(&:positive?).uniq
        end


        def bulk_delegate_issues(repository, issue_numbers)
          client = GithubClient.for(repository: repository, user: Current.user)
          issue_numbers.each do |issue_number|
            client.add_label_to_issue(repository.slug, issue_number, repository.trigger_label)
          end

          render json: repository_issues_payload(
            repository,
            state: issue_state,
            message: I18n.t("api.repositories.bulk_delegated", count: issue_numbers.size)
          )
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.bulk_delegate_failed", error: e.message), status: :bad_gateway)
        end


        def bulk_close_issues(repository, issue_numbers)
          client = GithubClient.for(repository: repository, user: Current.user)
          issue_numbers.each do |issue_number|
            client.close_issue(repository.slug, issue_number)
          end

          render json: repository_issues_payload(
            repository,
            state: issue_state,
            message: I18n.t("api.repositories.bulk_closed", count: issue_numbers.size)
          )
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.bulk_close_failed", error: e.message), status: :bad_gateway)
        end


        private

        def find_repository
          ::Repository.accessible_to(Current.user).find(params[:repository_id] || params[:id])
        end
      end
    end
  end
end
