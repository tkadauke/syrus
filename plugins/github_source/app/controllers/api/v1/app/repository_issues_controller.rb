module Api
  module V1
    module App
      # GitHub issue browsing and triage actions for the repository page.
      #
      # Lives in the github_source plugin: listing, closing, and delegating
      # issues are GitHub-specific operations, and an instance whose work
      # arrives from somewhere else has no use for them.
      class RepositoryIssuesController < BaseController
        include RepositoryTabsSerialization
        include RepositorySummarySerialization

        # Smart folders over the open/closed issue sets GitHub already gives
        # us -- "inbox" and "delegated" partition the open set by whether it
        # carries the repository's trigger label, so no extra GitHub calls
        # are needed beyond the open/closed fetches every folder already
        # requires for accurate counts (see #repository_issues_payload).
        FOLDERS = %w[inbox delegated open closed].freeze
        ISSUES_PER_PAGE = 50

        def issues
          repository = find_repository
          render json: repository_issues_payload(repository, folder: issue_folder, filter: issue_filter)
        end

        def close_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).close_issue(repository.slug, issue_number)

          render json: repository_issues_payload(repository, folder: issue_folder, filter: issue_filter, message: I18n.t("api.repositories.issue_closed", number: issue_number))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.issue_close_failed", error: e.message), status: :bad_gateway)
        end


        def delegate_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).add_label_to_issue(repository.slug, issue_number, repository.trigger_label)

          render json: repository_issues_payload(repository, folder: issue_folder, filter: issue_filter, message: I18n.t("api.repositories.issue_delegated", number: issue_number))
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


        # Fetches both open and closed issues on every call so every smart
        # folder's count is accurate (not just the currently selected one) --
        # GithubClient#list_all_issues already auto-paginates through the
        # full set per state, so this adds no truncation risk, only a second
        # (cheap, conditionally-cached) GitHub request.
        def repository_issues_payload(repository, folder:, filter:, message: nil)
          open_issues = []
          closed_issues = []
          error_message = nil
          client = nil
          begin
            client = GithubClient.for(repository: repository, user: Current.user)
            open_issues = client.list_all_issues(repository.slug, state: "open")
            closed_issues = client.list_all_issues(repository.slug, state: "closed")
          rescue ArgumentError
            error_message = I18n.t("api.repositories.no_github_token")
          rescue Octokit::Error => e
            error_message = I18n.t("api.repositories.github_error", error: e.message)
          end

          delegated_issues, inbox_issues = open_issues.partition { |issue| issue_delegated?(repository, issue) }
          folder_issues = {
            "inbox" => inbox_issues,
            "delegated" => delegated_issues,
            "open" => open_issues,
            "closed" => closed_issues
          }
          matching_issues = filter_by_query(folder_issues.fetch(folder), filter.query)
          visible_issues = matching_issues.first(ISSUES_PER_PAGE)
          linked_pull_requests = linked_pull_requests_for(repository, client, visible_issues)

          {
            message: message,
            error_message: error_message,
            repository: repository_detail_json(repository),
            tabs: repository_tabs_json(repository),
            folder: folder,
            query: filter.query,
            filter: filter.to_h,
            filter_schema: GithubSource::IssuesFilter.schema,
            issue_count: matching_issues.size,
            issues: visible_issues.map { |issue| issue_json(repository, issue, linked_pull_requests.fetch(issue.number, nil)) },
            folder_counts: folder_issues.transform_values(&:size),
            folder_paths: FOLDERS.index_with { |value| "/repositories/#{repository.id}/plugin/issues?folder=#{value}" },
            paths: {
              github_issues_path: "https://github.com/#{repository.slug}/issues",
              app_close_issue_path: "/api/v1/app/repositories/#{repository.id}/issues/close",
              app_delegate_issue_path: "/api/v1/app/repositories/#{repository.id}/issues/delegate",
              app_bulk_issues_path: "/api/v1/app/repositories/#{repository.id}/issues/bulk"
            }
          }
        end


        def issue_json(repository, issue, linked_pull_request = nil)
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
            delegated: issue_delegated?(repository, issue),
            linked_pull_request: linked_pull_request
          }
        end


        def linked_pull_requests_for(repository, client, issues)
          return {} unless client

          issue_numbers = issues
            .select { |issue| issue.state.to_s == "open" }
            .map(&:number)
          return {} if issue_numbers.empty?

          client.linked_open_prs_for_issues(repository.slug, issue_numbers)
        rescue Octokit::Error => e
          Rails.logger.warn("[RepositoryIssuesController] linked PR lookup failed for #{repository.slug}: #{e.class}: #{e.message}")
          {}
        end


        def issue_delegated?(repository, issue)
          Array(issue.labels).any? { |label| label.name == repository.trigger_label }
        end


        def issue_label_json(label)
          {
            name: label.name.to_s,
            color: label.color.to_s.presence || "6b7280"
          }
        end


        def filter_by_query(issues, query)
          return issues if query.blank?

          needle = query.downcase
          issues.select do |issue|
            issue.title.to_s.downcase.include?(needle) ||
              issue.body.to_s.downcase.include?(needle) ||
              issue.user&.login.to_s.downcase.include?(needle)
          end
        end


        def issue_folder
          folder = params[:folder].presence
          return folder if FOLDERS.include?(folder)
          return "closed" if params[:state] == "closed"

          "open"
        end


        def issue_filter
          GithubSource::IssuesFilter.from_params(params)
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
            folder: issue_folder,
            filter: issue_filter,
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
            folder: issue_folder,
            filter: issue_filter,
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
