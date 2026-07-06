module Api
  module V1
    module App
      class RepositoriesController < BaseController
        PER_PAGE = 20

        def index
          render json: repositories_payload
        end

        def show
          repository = find_repository

          render json: repository_detail_payload(repository, page: detail_page)
        end

        def issues
          repository = find_repository
          render json: repository_issues_payload(repository, state: issue_state)
        end

        def new
          render json: form_payload(Repository.new(default_branch: "main", trigger_label: "syrus"))
        end

        def edit
          render json: form_payload(find_repository)
        end

        def owners
          render json: GithubClient.for_user(Current.user).accessible_owners
        rescue ArgumentError
          render json: { error: "no_token" }
        rescue Octokit::Unauthorized, Octokit::Forbidden
          render json: { error: "unauthorized" }
        rescue StandardError
          render json: { error: "error" }
        end

        def repos
          owner = params[:owner].to_s.strip
          return render json: { error: "missing_params" } if owner.blank?

          owner_type = params[:owner_type].to_s.strip
          render json: { repos: GithubClient.for_user(Current.user).owner_repos(owner, owner_type: owner_type) }
        rescue ArgumentError
          render json: { error: "no_token" }
        rescue Octokit::NotFound, Octokit::Unauthorized, Octokit::Forbidden
          render json: { error: "not_found" }
        rescue StandardError
          render json: { error: "error" }
        end

        def branches
          owner = params[:owner].to_s.strip
          name = params[:name].to_s.strip
          if owner.blank? || name.blank?
            render json: { error: "missing_params" }
            return
          end

          render json: GithubClient.for_user(Current.user).repo_branches("#{owner}/#{name}")
        rescue Octokit::NotFound, Octokit::Unauthorized, Octokit::Forbidden
          render json: { error: "not_found" }
        rescue StandardError
          render json: { error: "error" }
        end

        def create
          attrs = repository_params
          repository = Repository.find_or_initialize_by(
            owner: attrs[:owner].to_s.strip,
            name: attrs[:name].to_s.strip
          )

          if repository.new_record?
            repository.assign_attributes(attrs)
            repository.user = Current.user
            unless repository.save
              render_error("validation_failed", repository.errors.full_messages.to_sentence, status: :unprocessable_content)
              return
            end
            repository.repository_memberships.find_or_create_by!(user: Current.user) { |m| m.role = "owner" }
          else
            if repository.repository_memberships.exists?(user: Current.user)
              render_error("validation_failed", I18n.t("api.repositories.already_in_workspace", slug: repository.slug), status: :unprocessable_content)
              return
            end
            repository.repository_memberships.create!(user: Current.user, role: "collaborator")
          end

          render json: saved_payload(repository, message: I18n.t("api.repositories.added", slug: repository.slug)), status: :created
        end

        def update
          repository = find_repository

          if repository.update(repository_params)
            render json: saved_payload(repository, message: I18n.t("api.repositories.updated", slug: repository.slug))
          else
            render_error("validation_failed", repository.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
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

        def poll
          repository = find_repository
          if repository.archived?
            render_error("validation_failed", I18n.t("api.repositories.archived_first", slug: repository.slug), status: :unprocessable_content)
            return
          end

          PollRepositoryJob.perform_later(repository.id, force: true)
          message = I18n.t("api.repositories.polling", slug: repository.slug)
          render json: repository_command_payload(repository, message: message)
        end

        def archive
          repository = find_repository
          repository.archive!
          render json: repositories_payload(message: I18n.t("api.repositories.archived", slug: repository.slug))
        end

        def unarchive
          repository = find_repository
          repository.unarchive!
          render json: repositories_payload(message: I18n.t("api.repositories.unarchived", slug: repository.slug))
        end

        def retry_failed_jobs
          repository = find_repository
          eligible = retryable_failed_jobs(repository)
          if eligible.empty?
            render_error("validation_failed", I18n.t("api.repositories.no_failed_jobs"), status: :unprocessable_content)
            return
          end

          agent_provider = repository.effective_agent_provider
          circuit = ProviderCircuitBreaker.call(agent_provider)
          if circuit.open?
            render_error("provider_circuit_open", provider_circuit_message(circuit), status: :unprocessable_content)
            return
          end

          retried = eligible.count do |job|
            RetryWorkflowEnqueuer.call(
              job: job,
              agent_provider: agent_provider,
              provider_validation: :none,
              automatic: true
            ).success?
          end

          render json: repository_detail_payload(
            repository.reload,
            page: detail_page,
            message: I18n.t("api.repositories.retry_enqueued", count: retried, provider: agent_provider.titleize)
          )
        end

        def release_needs_triage_job
          repository = find_repository
          unless can_release_triage_jobs?
            render_error("forbidden", I18n.t("api.repositories.developer_required"), status: :forbidden)
            return
          end

          job = repository.jobs.find(params.require(:job_id))
          unless job.needs_triage?
            render_error("validation_failed", I18n.t("api.repositories.not_triage"), status: :unprocessable_content)
            return
          end

          StateTransition.with_source("operator", user: Current.user) do
            job.release_for_triage!
            job.save!
          end
          continue_released_job_triage(job)

          render json: repository_detail_payload(
            repository.reload,
            page: detail_page,
            message: I18n.t("api.repositories.released_triage", slug: job.slug)
          )
        end

        def coverage_trend
          repository = find_repository
          days = [ params.fetch(:days, 30).to_i, 1 ].max

          averages = CoverageSnapshot.daily_averages(repository: repository, days: days)
          latest_snapshot = CoverageSnapshot.on_branch(repository.default_branch)
                                            .order(created_at: :desc)
                                            .first

          trend = averages.map do |row|
            {
              "date" => row.date.to_s,
              "lines_pct" => row.avg_lines_pct&.to_f&.round(2),
              "branches_pct" => row.avg_branches_pct&.to_f&.round(2),
              "functions_pct" => row.avg_functions_pct&.to_f&.round(2)
            }
          end

          latest = if latest_snapshot
            {
              "lines_pct" => latest_snapshot.lines_pct&.to_f,
              "branches_pct" => latest_snapshot.branches_pct&.to_f,
              "functions_pct" => latest_snapshot.functions_pct&.to_f
            }
          end

          render json: { "days" => days, "trend" => trend, "latest" => latest }
        end

        private

        def form_payload(repository)
          {
            repository: repository_form_json(repository),
            configured_agent_providers: User::AGENT_PROVIDERS.map { |provider| provider_json(provider) },
            user_agent_provider_label: agent_provider_label(Current.user.agent_provider),
            auto_approve_modes: auto_approve_modes_json,
            repositories_path: repositories_path
          }
        end

        def saved_payload(repository, message:)
          {
            message: message,
            redirect_to: repositories_path,
            repository: repository_json(repository),
            # Lets the add-repository flow offer the pre-scoped App install
            # link right when it is actionable (and skip it when the owner's
            # installation already covers the repo).
            credential_status: credential_status_json(repository)
          }
        end

        def repository_detail_payload(repository, page:, message: nil)
          jobs_scope = repository.jobs
            .includes(:runs, :scheduled_task, workflows: :steps)
            .order(updated_at: :desc)
          total_jobs = repository.jobs.count
          total_pages = [ (total_jobs / PER_PAGE.to_f).ceil, 1 ].max
          jobs = jobs_scope
            .limit(PER_PAGE)
            .offset((page - 1) * PER_PAGE)

          {
            message: message,
            repository: repository_detail_json(repository),
            tabs: repository_tabs_json(repository),
            counts: repository_counts_json(repository),
            retry_failed_jobs: retry_failed_jobs_json(repository),
            can_release_triage_jobs: can_release_triage_jobs?,
            needs_triage_jobs: needs_triage_jobs_json(repository),
            credential_status: credential_status_json(repository),
            jobs: jobs.map { |job| job_json(job) },
            pagination: pagination_json(page: page, total_jobs: total_jobs, total_pages: total_pages, repository: repository),
            paths: {
              new_job_path: new_job_path(repository_id: repository.id),
              edit_repository_path: edit_repository_path(repository),
              app_poll_repository_path: "/api/v1/app/repositories/#{repository.id}/poll",
              app_archive_repository_path: "/api/v1/app/repositories/#{repository.id}/archive",
              app_retry_failed_jobs_repository_path: "/api/v1/app/repositories/#{repository.id}/retry_failed_jobs",
              app_release_needs_triage_job_repository_path: "/api/v1/app/repositories/#{repository.id}/release_needs_triage_job",
              repositories_path: repositories_path,
              repository_documents_path: repository_documents_path(repository),
              repository_scheduled_tasks_path: repository_scheduled_tasks_path(repository)
            }
          }
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

        def repositories_payload(message: nil)
          repos = Current.user.repositories.order(:owner, :name)
          {
            active_repositories: repos.active.map { |repository| repository_json(repository) },
            archived_repositories: repos.archived.map { |repository| repository_json(repository) },
            repositories: repos.map { |repository| repository_cli_json(repository) },
            new_repository_path: new_repository_path,
            setup: ::App::SetupStatus.call(user: Current.user),
            message: message
          }
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            owner: repository.owner,
            name: repository.name,
            owner_user: owner_user_json(repository.user),
            default_branch: repository.default_branch,
            upstream_owner: repository.upstream_owner,
            upstream_name: repository.upstream_name,
            upstream_default_branch: repository.upstream_default_branch,
            upstream_slug: repository.upstream_slug,
            trigger_label: repository.trigger_label,
            polling_enabled: repository.polling_enabled?,
            archived: repository.archived?,
            archived_at: repository.archived_at&.iso8601,
            agent_provider: repository.agent_provider,
            agent_provider_label: repository.agent_provider.present? ? agent_provider_label(repository.agent_provider) : "default",
            last_poll_status: repository.last_poll_status,
            last_poll_started_at: repository.last_poll_started_at&.iso8601,
            last_poll_error: repository.last_poll_error,
            repository_path: repository_path(repository),
            edit_repository_path: edit_repository_path(repository)
          }
        end

        def repository_cli_json(repository)
          jobs = repository.jobs.order(updated_at: :desc)
          last_job = jobs.first
          {
            id: repository.id,
            slug: repository.slug,
            archived: repository.archived?,
            active_jobs_count: repository.jobs.open_threads.count,
            last_job: last_job && {
              id: last_job.id,
              title: last_job.issue_title.to_s,
              state: last_job.state,
              updated_at: last_job.updated_at&.iso8601
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

        def repository_detail_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            owner: repository.owner,
            name: repository.name,
            default_branch: repository.default_branch,
            upstream_owner: repository.upstream_owner,
            upstream_name: repository.upstream_name,
            upstream_default_branch: repository.upstream_default_branch,
            upstream_slug: repository.upstream_slug,
            trigger_label: repository.trigger_label,
            polling_enabled: repository.polling_enabled?,
            archived: repository.archived?,
            agent_provider: repository.agent_provider,
            agent_provider_label: repository.agent_provider.present? ? agent_provider_label(repository.agent_provider) : nil,
            effective_agent_provider: repository.effective_agent_provider,
            effective_agent_provider_label: agent_provider_label(repository.effective_agent_provider),
            github_url: "https://github.com/#{repository.slug}",
            created_at: repository.created_at.iso8601,
            owner_user: owner_user_json(repository.user),
            github_rate_limit: github_rate_limit_json(repository.user)
          }
        end

        def owner_user_json(user)
          return nil unless user

          {
            id: user.id,
            display_name: user.team_display_name,
            email_address: user.email_address,
            admin: user.admin?,
            profile_path: profile_path(user)
          }
        end

        def repository_form_json(repository)
          {
            id: repository.id,
            owner: repository.owner.to_s,
            name: repository.name.to_s,
            slug: repository.persisted? ? repository.slug : nil,
            default_branch: repository.default_branch.to_s,
            upstream_owner: repository.upstream_owner.to_s,
            upstream_name: repository.upstream_name.to_s,
            upstream_default_branch: repository.upstream_default_branch.to_s,
            trigger_label: repository.trigger_label.to_s,
            polling_enabled: repository.polling_enabled?,
            prepare_enabled: repository.prepare_enabled?,
            pr_cost_footer_enabled: repository.pr_cost_footer_enabled?,
            auto_merge_enabled: repository.auto_merge_enabled?,
            trust_clean_rebase_grade: repository.trust_clean_rebase_grade?,
            agent_provider: repository.agent_provider.to_s,
            auto_approve_mode: repository.auto_approve_mode,
            feedback_policy: repository.feedback_policy,
            github_owner_id: repository.github_owner_id,
            github_repository_id: repository.github_repository_id,
            repository_path: repository.persisted? ? repository_path(repository) : nil
          }
        end

        def repository_tabs_json(repository)
          [
            { key: "overview", label: "Overview", path: repository_path(repository) },
            { key: "github_issues", label: "GitHub Issues", path: repository_path(repository, tab: "github_issues") },
            { key: "documents", label: "Documents", path: repository_documents_path(repository) },
            { key: "scheduled_tasks", label: "Scheduled Tasks", path: repository_scheduled_tasks_path(repository) }
          ]
        end

        def repository_counts_json(repository)
          {
            running: repository.jobs.joins(:runs).where(runs: { state: "running" }).distinct.count,
            queued: repository.jobs.joins(:runs).where(runs: { state: "queued" }).distinct.count,
            failed_7d: repository.jobs
              .joins(:runs)
              .where(runs: { state: "failed", updated_at: 7.days.ago.. })
              .distinct
              .count
          }
        end

        def retry_failed_jobs_json(repository)
          retryable = repository.jobs.open_threads.select { |job| !job.any_active_run? && job.current_run&.failed? }
          circuit = ProviderCircuitBreaker.call(repository.effective_agent_provider)
          {
            count: retryable.size,
            agent_provider: repository.effective_agent_provider,
            agent_provider_label: agent_provider_label(repository.effective_agent_provider),
            provider_circuit: circuit.as_json
          }
        end

        def needs_triage_jobs_json(repository)
          return [] unless can_release_triage_jobs?

          repository.jobs
            .needs_triage
            .includes(:owner_user)
            .order(created_at: :asc)
            .map { |job| needs_triage_job_json(job) }
        end

        def needs_triage_job_json(job)
          {
            id: job.id,
            issue_title: job.issue_title.to_s,
            issue_number: job.issue_number,
            job_path: job_path(job),
            source: job_source_json(job),
            owner_user: job.owner_user ? owner_user_json(job.owner_user) : nil,
            created_at: job.created_at.iso8601
          }
        end

        def can_release_triage_jobs?
          Current.user&.admin? || Current.user&.developer?
        end

        def continue_released_job_triage(job)
          if job.issue? && job.triaging_reason_classifier_pending? && job.user.agent_provider_configured?(job.agent_provider)
            ClassifyIssueJob.perform_later(job.id)
          elsif job.may_advance_after_triage?
            job.advance_after_triage!
          end
        end

        def provider_circuit_message(circuit)
          label = agent_provider_label(circuit.provider)
          if circuit.retry_after
            I18n.t("api.repositories.circuit_open_until", label: label, until: circuit.retry_after.to_fs(:db))
          else
            I18n.t("api.repositories.circuit_open", label: label)
          end
        end

        def credential_status_json(repository)
          if repository.app_credential_active?
            return {
              mode: "app",
              label: "GitHub App active",
              installation_account: repository.installation.account_login,
              github_app_registered: AppSetting.github_app_registered?,
              install_url: nil,
              generic_install_url: nil,
              register_path: nil,
              previous_installation_removed: false,
              missing_github_ids: false
            }
          end

          install_url = AppSetting.github_app_registered? ? ::App::Presentation.github_app_install_url_for(repository) : nil
          {
            mode: "pat",
            label: "PAT fallback: no active App installation",
            installation_account: nil,
            github_app_registered: AppSetting.github_app_registered?,
            install_url: install_url,
            # Account-level page (GitHub defaults it to "All repositories") —
            # offered alongside the pre-scoped link so operators can cover
            # every current and future repo in one go.
            generic_install_url: AppSetting.github_app_registered? ? ::App::Presentation.github_app_generic_install_url : nil,
            register_path: Current.user.admin? && !AppSetting.github_app_registered? ? admin_github_app_register_path : nil,
            previous_installation_removed: repository.installation&.removed_at.present?,
            missing_github_ids: AppSetting.github_app_registered? && install_url.blank?
          }
        end

        def github_rate_limit_json(user)
          return nil unless user&.gh_rate_limit_observed_at

          {
            remaining: user.gh_rate_limit_remaining,
            limit: user.gh_rate_limit_limit,
            resource: user.gh_rate_limit_resource || "core",
            observed_at: user.gh_rate_limit_observed_at.iso8601
          }
        end

        def note_json(repository, note)
          {
            id: note.id,
            body: note.body,
            author: note.author,
            created_at: note.created_at.iso8601,
            app_delete_path: "/api/v1/app/repositories/#{repository.id}/notes/#{note.id}"
          }
        end

        def job_json(job)
          {
            id: job.id,
            state: ::App::Presentation.job_summary_state(job),
            priority: job.priority,
            issue_number: job.issue_number,
            issue_title: job.issue_title.to_s,
            job_path: job_path(job),
            source: job_source_json(job),
            pr_number: job.pr_number,
            pr_url: ::App::Presentation.job_pr_url(job),
            external_pr_number: job.external_pr_number,
            external_pr_url: ::App::Presentation.external_pr_url(job),
            current_step_caption: ::App::Presentation.current_step_caption(job),
            retry_state: ::App::RetryState.for(job),
            runs_count: job.runs.size,
            updated_at: job.updated_at.iso8601
          }
        end

        def job_source_json(job)
          if job.cron?
            task = job.scheduled_task
            return {
              label: task ? "scheduled: #{task.name}" : "scheduled task ##{job.scheduled_task_id}",
              path: task ? scheduled_task_path(task) : nil,
              external: false
            }
          end

          if job.direct?
            return { label: "Direct", path: nil, external: false }
          end

          {
            label: "##{job.issue_number}",
            path: ::App::Presentation.job_issue_url(job),
            external: true
          }
        end

        def pagination_json(page:, total_jobs:, total_pages:, repository:)
          first_item = total_jobs.zero? ? 0 : ((page - 1) * PER_PAGE) + 1
          last_item = [ page * PER_PAGE, total_jobs ].min

          {
            page: page,
            per_page: PER_PAGE,
            total_jobs: total_jobs,
            total_pages: total_pages,
            first_item: first_item,
            last_item: last_item,
            previous_path: page > 1 ? repository_path(repository, page: page - 1) : nil,
            next_path: page < total_pages ? repository_path(repository, page: page + 1) : nil
          }
        end

        def provider_json(provider)
          {
            value: provider,
            label: agent_provider_label(provider)
          }
        end

        def auto_approve_modes_json
          [
            {
              value: "never",
              label: "Never",
              preview: "No direct rule; Jobs can still inherit a repository or user default."
            },
            {
              value: "if_graders_pass",
              label: "If graders pass",
              preview: "Jobs using this rule enter landing after repo-committed graders pass."
            },
            {
              value: "if_graders_pass_and_tagged_safe",
              label: "If graders pass and tagged safe",
              preview: "Jobs using this rule also need the safe tag before landing."
            }
          ]
        end

        def find_repository
          Current.user.repositories.find(params[:id])
        end

        def repository_command_payload(repository, message:)
          if params[:return_to] == "detail"
            repository_detail_payload(repository.reload, page: detail_page, message: message)
          else
            repositories_payload(message: message)
          end
        end

        def retryable_failed_jobs(repository)
          repository.jobs.open_threads.select do |job|
            !job.any_active_run? && job.current_run&.failed?
          end
        end

        def detail_page
          [ params.fetch(:page, 1).to_i, 1 ].max
        end

        def repository_params
          params.require(:repository).permit(
            :owner,
            :name,
            :default_branch,
            :upstream_owner,
            :upstream_name,
            :upstream_default_branch,
            :trigger_label,
            :polling_enabled,
            :prepare_enabled,
            :agent_provider,
            :pr_cost_footer_enabled,
            :auto_merge_enabled,
            :trust_clean_rebase_grade,
            :auto_approve_mode,
            :feedback_policy,
            :github_repository_id,
            :github_owner_id
          )
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

        def agent_provider_label(provider)
          ::App::Presentation.agent_provider_label(provider)
        end
      end
    end
  end
end
