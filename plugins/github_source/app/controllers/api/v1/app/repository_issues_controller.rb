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

        # Smart folders over the poll-synchronized local issue cache.
        FOLDERS = %w[inbox delegated open closed].freeze
        ISSUES_PER_PAGE = 50
        SORT_COLUMNS = %w[number title state author created_at delegated].freeze
        SORT_DIRECTIONS = %w[asc desc].freeze

        def issues
          repository = find_repository
          render json: repository_issues_payload(repository, folder: issue_folder, filter: issue_filter, sort: issue_sort)
        end

        def close_issue
          repository = find_writable_repository
          return unless repository

          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).close_issue(repository.slug, issue_number)
          GithubSource::Issue.where(repository: repository).where(number: issue_number).update_all(state: "closed", synced_at: Time.current)

          render json: repository_issues_payload(repository, folder: issue_folder, filter: issue_filter, sort: issue_sort, message: I18n.t("api.repositories.issue_closed", number: issue_number))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.issue_close_failed", error: e.message), status: :bad_gateway)
        end


        def delegate_issue
          repository = find_writable_repository
          return unless repository

          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).add_label_to_issue(repository.slug, issue_number, repository.trigger_label)
          mark_cached_issues_delegated!(repository, [ issue_number ])

          render json: repository_issues_payload(repository, folder: issue_folder, filter: issue_filter, sort: issue_sort, message: I18n.t("api.repositories.issue_delegated", number: issue_number))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.issue_delegate_failed", error: e.message), status: :bad_gateway)
        end


        def bulk_issues
          repository = find_writable_repository
          return unless repository

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


        # Reads both states locally so all smart-folder counts stay accurate.
        def repository_issues_payload(repository, folder:, filter:, sort: issue_sort, message: nil)
          open_issues = GithubSource::Issue.where(repository: repository).open.to_a
          closed_issues = GithubSource::Issue.where(repository: repository).closed.to_a
          error_message = repository.last_poll_status == "failed" ? repository.last_poll_error : nil

          delegated_issues, inbox_issues = open_issues.partition { |issue| issue_delegated?(repository, issue) }
          folder_issues = {
            "inbox" => inbox_issues,
            "delegated" => delegated_issues,
            "open" => open_issues,
            "closed" => closed_issues
          }
          matching_issues = sort_issues(repository, filter_issues(repository, folder_issues.fetch(folder), filter), sort)
          visible_issues = matching_issues.first(ISSUES_PER_PAGE)

          {
            message: message,
            error_message: error_message,
            freshness: {
              synchronized: repository.github_issues_synced_at.present?,
              synced_at: repository.github_issues_synced_at&.iso8601,
              full_synced_at: repository.github_issues_full_synced_at&.iso8601,
              stale: repository.last_poll_status == "failed",
              error: repository.last_poll_error
            },
            repository: repository_detail_json(repository),
            tabs: repository_tabs_json(repository),
            folder: folder,
            query: filter.query,
            filter: filter.to_h,
            filter_schema: GithubSource::IssuesFilter.schema,
            sort: sort,
            issue_count: matching_issues.size,
            issues: visible_issues.map { |issue| issue_json(repository, issue) },
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


        def issue_json(repository, issue)
          {
            number: issue.number,
            title: issue.title.to_s,
            state: issue.state.to_s,
            html_url: issue.html_url.to_s,
            body_excerpt: issue.body_excerpt,
            user_login: issue.author_login,
            created_at: issue.github_created_at&.iso8601,
            labels: issue.labels,
            delegated: issue_delegated?(repository, issue),
            linked_pull_request: issue.linked_open_pr
          }
        end


        def issue_delegated?(repository, issue)
          issue.delegated?(repository.trigger_label)
        end


        def filter_issues(repository, issues, filter)
          issues
            .then { |filtered| filter_by_query(filtered, filter.query) }
            .then { |filtered| filter_by_author(filtered, filter.author) }
            .then { |filtered| filter_by_label(filtered, filter.label) }
            .then { |filtered| filter_by_state(filtered, filter.state) }
            .then { |filtered| filter_by_delegated(repository, filtered, filter.delegated) }
        end


        def filter_by_query(issues, query)
          return issues if query.blank?

          needle = query.downcase
          issues.select do |issue|
            issue.title.to_s.downcase.include?(needle) ||
              issue.body.to_s.downcase.include?(needle) ||
              issue.author_login.to_s.downcase.include?(needle)
          end
        end


        def filter_by_author(issues, author)
          return issues if author.blank?

          needle = author.downcase
          issues.select { |issue| issue.author_login.to_s.downcase.include?(needle) }
        end


        def filter_by_label(issues, label)
          return issues if label.blank?

          needle = label.downcase
          issues.select do |issue|
            issue.labels.any? { |issue_label| issue_label["name"].to_s.downcase.include?(needle) }
          end
        end


        def filter_by_state(issues, state)
          return issues if state.blank?

          issues.select { |issue| issue.state.to_s == state }
        end


        def filter_by_delegated(repository, issues, delegated)
          return issues if delegated.nil?

          issues.select { |issue| issue_delegated?(repository, issue) == delegated }
        end


        def sort_issues(repository, issues, sort)
          sorted = issues.sort_by { |issue| issue_sort_value(repository, issue, sort.fetch(:column)) }
          sort.fetch(:direction) == "desc" ? sorted.reverse : sorted
        end


        def issue_sort_value(repository, issue, column)
          values = {
            "number" => [ issue.number.to_i ],
            "title" => [ issue.title.to_s.downcase, issue.number.to_i ],
            "state" => [ issue.state.to_s, issue.number.to_i ],
            "author" => [ issue.author_login.to_s.downcase, issue.number.to_i ],
            "created_at" => [ issue.github_created_at || Time.zone.at(0), issue.number.to_i ],
            "delegated" => [ issue_delegated?(repository, issue) ? 1 : 0, issue.number.to_i ]
          }
          values.fetch(column)
        end


        def issue_folder
          folder = params[:folder].presence
          return folder if FOLDERS.include?(folder)
          return "closed" if params[:state] == "closed"

          "open"
        end


        def issue_sort
          {
            column: params[:sort].presence_in(SORT_COLUMNS) || "created_at",
            direction: params[:direction].presence_in(SORT_DIRECTIONS) || "desc"
          }
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
            mark_cached_issues_delegated!(repository, [ issue_number ])
          end

          render json: repository_issues_payload(
            repository,
            folder: issue_folder,
            filter: issue_filter,
            sort: issue_sort,
            message: I18n.t("api.repositories.bulk_delegated", count: issue_numbers.size)
          )
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.bulk_delegate_failed", error: e.message), status: :bad_gateway)
        end


        def bulk_close_issues(repository, issue_numbers)
          client = GithubClient.for(repository: repository, user: Current.user)
          issue_numbers.each do |issue_number|
            client.close_issue(repository.slug, issue_number)
            GithubSource::Issue.where(repository: repository, number: issue_number).update_all(state: "closed", synced_at: Time.current)
          end

          render json: repository_issues_payload(
            repository,
            folder: issue_folder,
            filter: issue_filter,
            sort: issue_sort,
            message: I18n.t("api.repositories.bulk_closed", count: issue_numbers.size)
          )
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.bulk_close_failed", error: e.message), status: :bad_gateway)
        end


        private

        def mark_cached_issues_delegated!(repository, issue_numbers)
          GithubSource::Issue.where(repository: repository).where(number: issue_numbers).find_each do |issue|
            next if issue.delegated?(repository.trigger_label)

            issue.update!(labels: issue.labels + [ { "name" => repository.trigger_label, "color" => "6b7280" } ], synced_at: Time.current)
          end
        end

        def find_repository
          find_readable_repository(params[:repository_id] || params[:id])
        end
      end
    end
  end
end
