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
        FOLDERS = %w[all inbox delegated open closed].freeze
        ISSUES_PER_PAGE = 50
        SORT_COLUMNS = %w[number title state author created_at delegated].freeze
        SORT_DIRECTIONS = %w[asc desc].freeze

        def issues
          repository = find_repository
          render json: repository_issues_payload(repository, folder: issue_folder, filter: issue_filter, sort: issue_sort, page: issue_page)
        end

        def close_issue
          repository = find_writable_repository
          return unless repository

          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).close_issue(repository.slug, issue_number)
          GithubSource::Issue.where(repository: repository).where(number: issue_number).update_all(state: "closed", synced_at: Time.current)

          render json: issue_mutation_payload(repository, [ issue_number ], I18n.t("api.repositories.issue_closed", number: issue_number))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.issue_close_failed", error: e.message), status: :bad_gateway)
        end


        def delegate_issue
          repository = find_writable_repository
          return unless repository

          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).add_label_to_issue(repository.slug, issue_number, repository.trigger_label)
          mark_cached_issues_delegated!(repository, [ issue_number ])

          render json: issue_mutation_payload(repository, [ issue_number ], I18n.t("api.repositories.issue_delegated", number: issue_number))
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
        def repository_issues_payload(repository, folder:, filter:, sort: issue_sort, page: issue_page, message: nil)
          scope = GithubSource::Issue.where(repository: repository)
          error_message = repository.last_poll_status == "failed" ? repository.last_poll_error : nil
          matching_issues = filter_issue_scope(repository, scope, filter)
          issue_count = matching_issues.count
          visible_issues = sort_issue_scope(repository, matching_issues, sort)
            .select(issue_list_columns)
            .offset((page - 1) * ISSUES_PER_PAGE).limit(ISSUES_PER_PAGE)

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
            repository: issues_repository_json(repository),
            tabs: repository_tabs_json(repository),
            folder: folder,
            query: filter.query,
            filter: filter.to_h,
            untouched_preset: !explicit_issue_filter? && filter.preset.present?,
            filter_schema: GithubSource::IssuesFilter.schema,
            sort: sort,
            page: page,
            per_page: ISSUES_PER_PAGE,
            total_pages: (issue_count.to_f / ISSUES_PER_PAGE).ceil,
            issue_count: issue_count,
            issues: visible_issues.map { |issue| issue_json(repository, issue) },
            folder_counts: issue_folder_counts(repository, scope),
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
            body_excerpt: issue[:body_excerpt_text].to_s.gsub(/\r?\n/, " ").truncate(180),
            user_login: issue.author_login,
            created_at: issue.github_created_at&.iso8601,
            labels: issue.labels,
            delegated: issue_delegated?(repository, issue),
            linked_pull_request: issue.linked_open_pr
          }
        end

        def issues_repository_json(repository)
          { id: repository.id, slug: repository.slug, github_url: "https://github.com/#{repository.slug}",
            trigger_label: repository.trigger_label, github_rate_limit: github_rate_limit_json(repository.user) }
        end

        def issue_list_columns
          %i[id number title state html_url author_login github_created_at labels linked_open_pr] +
            [ Arel.sql("SUBSTR(body, 1, 240) AS body_excerpt_text") ]
        end

        def delegated_sql(repository)
          label = ActiveRecord::Base.sanitize_sql_like(repository.trigger_label)
          [ "CAST(labels AS CHAR) LIKE ?", "%\"name\":\"#{label}\"%" ]
        end

        def issue_folder_counts(repository, scope)
          delegated = scope.open.where(delegated_sql(repository)).count
          opened = scope.open.count
          closed = scope.closed.count
          { all: opened + closed, inbox: opened - delegated, delegated: delegated, open: opened, closed: closed }
        end

        def filter_issue_scope(repository, scope, filter)
          scope = scope.where("LOWER(title) LIKE :q OR LOWER(body) LIKE :q OR LOWER(author_login) LIKE :q", q: "%#{ActiveRecord::Base.sanitize_sql_like(filter.query.downcase)}%") if filter.query.present?
          scope = scope.where("LOWER(author_login) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(filter.author.downcase)}%") if filter.author.present?
          scope = scope.where("LOWER(CAST(labels AS CHAR)) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(filter.label.downcase)}%") if filter.label.present?
          scope = scope.where(state: filter.state) if filter.state.present?
          scope = filter.delegated ? scope.where(delegated_sql(repository)) : scope.where.not(delegated_sql(repository)) unless filter.delegated.nil?
          scope
        end

        def sort_issue_scope(repository, scope, sort)
          column = { "number" => :number, "title" => :title, "state" => :state, "author" => :author_login, "created_at" => :github_created_at }.fetch(sort[:column], :number)
          return scope.order(Arel.sql("CASE WHEN #{ActiveRecord::Base.sanitize_sql_array(delegated_sql(repository))} THEN 1 ELSE 0 END #{sort[:direction].upcase}"), number: sort[:direction]) if sort[:column] == "delegated"

          scope.order(column => sort[:direction], number: sort[:direction])
        end


        def issue_delegated?(repository, issue)
          issue.delegated?(repository.trigger_label)
        end


        def issue_folder
          return "all" if explicit_issue_filter?

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

        def issue_page
          [ params.fetch(:page, 1).to_i, 1 ].max
        end


        def issue_filter
          GithubSource::IssuesFilter.for_request(params, folder: issue_folder)
        end

        def explicit_issue_filter?
          params.key?(::Filters::QueryParam::PARAM_NAME) || params.key?(::Filters::QueryParam::PARAM_NAME.to_s)
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

          render json: issue_mutation_payload(repository, issue_numbers, I18n.t("api.repositories.bulk_delegated", count: issue_numbers.size))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.bulk_delegate_failed", error: e.message), status: :bad_gateway)
        end


        def bulk_close_issues(repository, issue_numbers)
          client = GithubClient.for(repository: repository, user: Current.user)
          issue_numbers.each do |issue_number|
            client.close_issue(repository.slug, issue_number)
            GithubSource::Issue.where(repository: repository, number: issue_number).update_all(state: "closed", synced_at: Time.current)
          end

          render json: issue_mutation_payload(repository, issue_numbers, I18n.t("api.repositories.bulk_closed", count: issue_numbers.size))
        rescue Octokit::Error => e
          render_error("github_error", I18n.t("api.repositories.bulk_close_failed", error: e.message), status: :bad_gateway)
        end


        private

        def issue_mutation_payload(repository, issue_numbers, message)
          scope = GithubSource::Issue.where(repository: repository)
          {
            message: message,
            changed_issues: scope.where(number: issue_numbers).select(issue_list_columns).map { |issue| issue_json(repository, issue) },
            folder_counts: issue_folder_counts(repository, scope)
          }
        end

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
