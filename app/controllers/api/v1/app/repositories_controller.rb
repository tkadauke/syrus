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
          render json: form_payload(Current.user.repositories.build(default_branch: "main", trigger_label: "syrus"))
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
          repository = Current.user.repositories.build(repository_params)

          if repository.save
            render json: saved_payload(repository, message: "Repository #{repository.slug} added."), status: :created
          else
            render_error("validation_failed", repository.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def update
          repository = find_repository

          if repository.update(repository_params)
            render json: saved_payload(repository, message: "Repository #{repository.slug} updated.")
          else
            render_error("validation_failed", repository.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def create_note
          repository = find_repository
          body = params.dig(:repository_note, :body).to_s.strip
          if body.blank?
            render_error("validation_failed", "Context cannot be blank.", status: :unprocessable_content)
            return
          end

          repository.repository_notes.create!(body: body, author: "operator")
          render json: repository_detail_payload(repository.reload, page: detail_page, message: "Repository context pinned.")
        end

        def destroy_note
          repository = Current.user.repositories.find(params[:repository_id])
          note = repository.repository_notes.active.find(params[:id])
          note.remove!

          render json: repository_detail_payload(repository.reload, page: detail_page, message: "Repository context removed.")
        end

        def comment_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          body = params[:comment_body].to_s.strip
          if body.blank?
            render_error("validation_failed", "Comment cannot be blank.", status: :unprocessable_content)
            return
          end

          GithubClient.for(repository: repository, user: Current.user).add_issue_comment(
            repository.slug,
            issue_number,
            body,
            on_behalf_of: Current.user
          )

          render json: repository_issues_payload(repository, state: issue_state, message: "Comment added to ##{issue_number}.")
        rescue Octokit::Error => e
          render_error("github_error", "Failed to add comment: #{e.message}", status: :bad_gateway)
        end

        def close_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).close_issue(repository.slug, issue_number)

          render json: repository_issues_payload(repository, state: issue_state, message: "Issue ##{issue_number} closed.")
        rescue Octokit::Error => e
          render_error("github_error", "Failed to close issue: #{e.message}", status: :bad_gateway)
        end

        def delegate_issue
          repository = find_repository
          issue_number = params.require(:issue_number).to_i
          GithubClient.for(repository: repository, user: Current.user).add_label_to_issue(repository.slug, issue_number, repository.trigger_label)

          render json: repository_issues_payload(repository, state: issue_state, message: "Issue ##{issue_number} delegated to Syrus.")
        rescue Octokit::Error => e
          render_error("github_error", "Failed to delegate issue: #{e.message}", status: :bad_gateway)
        end

        def bulk_issues
          repository = find_repository
          issue_numbers = selected_issue_numbers
          if issue_numbers.empty?
            render_error("validation_failed", "Select at least one issue.", status: :unprocessable_content)
            return
          end

          case params[:bulk_action]
          when "delegate"
            bulk_delegate_issues(repository, issue_numbers)
          when "close"
            bulk_close_issues(repository, issue_numbers)
          else
            render_error("validation_failed", "Choose a bulk action.", status: :unprocessable_content)
          end
        end

        def poll
          repository = find_repository
          if repository.archived?
            render_error("validation_failed", "#{repository.slug} is archived — unarchive it first.", status: :unprocessable_content)
            return
          end

          PollRepositoryJob.perform_later(repository.id, force: true)
          message = "Polling #{repository.slug} now."
          render json: repository_command_payload(repository, message: message)
        end

        def archive
          repository = find_repository
          repository.archive!
          render json: repositories_payload(message: "#{repository.slug} archived.")
        end

        def unarchive
          repository = find_repository
          repository.unarchive!
          render json: repositories_payload(message: "#{repository.slug} unarchived. Re-enable polling to start ingestion again.")
        end

        def retry_failed_jobs
          repository = find_repository
          eligible = retryable_failed_jobs(repository)
          if eligible.empty?
            render_error("validation_failed", "No failed jobs to retry.", status: :unprocessable_content)
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
            message: "Retry enqueued for #{helpers.pluralize(retried, 'failed job')} with #{agent_provider.titleize}."
          )
        end

        def release_needs_triage_job
          repository = find_repository
          unless can_release_triage_jobs?
            render_error("forbidden", "Developer or admin access required.", status: :forbidden)
            return
          end

          job = repository.jobs.find(params.require(:job_id))
          unless job.needs_triage?
            render_error("validation_failed", "Job is not waiting for triage release.", status: :unprocessable_content)
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
            message: "Released JOB-#{job.id} for triage."
          )
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
            repository: repository_json(repository)
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
            notes: repository.repository_notes.active.order(created_at: :desc, id: :desc).map { |note| note_json(repository, note) },
            jobs: jobs.map { |job| job_json(job) },
            pagination: pagination_json(page: page, total_jobs: total_jobs, total_pages: total_pages, repository: repository),
            paths: {
              new_job_path: new_job_path(repository_id: repository.id),
              edit_repository_path: edit_repository_path(repository),
              app_poll_repository_path: "/api/v1/app/repositories/#{repository.id}/poll",
              app_archive_repository_path: "/api/v1/app/repositories/#{repository.id}/archive",
              app_retry_failed_jobs_repository_path: "/api/v1/app/repositories/#{repository.id}/retry_failed_jobs",
              app_release_needs_triage_job_repository_path: "/api/v1/app/repositories/#{repository.id}/release_needs_triage_job",
              app_repository_notes_path: "/api/v1/app/repositories/#{repository.id}/notes",
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
            error_message = "No GitHub token configured — add one in Settings."
          rescue Octokit::Error => e
            error_message = "GitHub error: #{e.message}"
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
            github_owner_id: repository.github_owner_id,
            github_repository_id: repository.github_repository_id,
            repository_path: repository.persisted? ? repository_path(repository) : nil
          }
        end

        def repository_tabs_json(repository)
          [
            { key: "overview", label: "Overview", path: repository_path(repository) },
            { key: "github_issues", label: "GitHub Issues", path: repository_path(repository, tab: "github_issues") },
            { key: "context", label: "Context", path: repository_path(repository, tab: "context") },
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
          until_text = circuit.retry_after ? " until #{circuit.retry_after.to_fs(:db)}" : ""
          "#{label} appears degraded#{until_text}; automatic retries are paused."
        end

        def credential_status_json(repository)
          if repository.app_credential_active?
            return {
              mode: "app",
              label: "GitHub App active",
              installation_account: repository.installation.account_login,
              github_app_registered: AppSetting.github_app_registered?,
              install_url: nil,
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
            register_path: Current.user.admin? && !AppSetting.github_app_registered? ? admin_github_app_register_path : nil,
            previous_installation_removed: repository.installation&.removed_at.present?,
            missing_github_ids: AppSetting.github_app_registered? && install_url.blank?
          }
        end

        def github_rate_limit_json(user)
          return nil unless user.gh_rate_limit_observed_at

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
            message: "#{helpers.pluralize(issue_numbers.size, 'issue')} delegated to Syrus."
          )
        rescue Octokit::Error => e
          render_error("github_error", "Failed to delegate issues: #{e.message}", status: :bad_gateway)
        end

        def bulk_close_issues(repository, issue_numbers)
          client = GithubClient.for(repository: repository, user: Current.user)
          issue_numbers.each do |issue_number|
            client.close_issue(repository.slug, issue_number)
          end

          render json: repository_issues_payload(
            repository,
            state: issue_state,
            message: "#{helpers.pluralize(issue_numbers.size, 'issue')} closed."
          )
        rescue Octokit::Error => e
          render_error("github_error", "Failed to close issues: #{e.message}", status: :bad_gateway)
        end

        def agent_provider_label(provider)
          ::App::Presentation.agent_provider_label(provider)
        end
      end
    end
  end
end
