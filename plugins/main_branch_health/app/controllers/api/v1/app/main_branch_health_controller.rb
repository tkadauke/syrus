module Api
  module V1
    module App
      # Plugin-owned main-branch health endpoints. Flat naming, like core's
      # repository-scoped controllers, so the module does not shadow ::Repositories.
      class MainBranchHealthController < BaseController
        def health_history
          repository = find_repository

          render json: { health_history: health_history_json(repository) }
        end

        def run_graders
          return unless (repository = find_repository_for_admin_mutation)
          if repository.archived?
            render_error("validation_failed", I18n.t("api.repositories.archived_first", slug: repository.slug), status: :unprocessable_content)
            return
          end

          sha = repository.last_health_checked_sha
          if sha.blank?
            render_error("validation_failed", I18n.t("api.repositories.no_sha_to_grade"), status: :unprocessable_content)
            return
          end

          MainGraderWorkflowJob.perform_later(repository.id, sha)
          message = I18n.t("api.repositories.run_main_branch_graders_enqueued", sha: sha[0, 7], slug: repository.slug)
          render json: { message: message }
        end

        def repair
          return unless (repository = find_repository_for_admin_mutation)
          if repository.archived?
            render_error("validation_failed", I18n.t("api.repositories.archived_first", slug: repository.slug), status: :unprocessable_content)
            return
          end

          service = MainHealthChangedService.new(repository)
          status = service.repair_status
          if status[:blocking_job]
            message = I18n.t("api.repositories.main_branch_repair_existing", slug: status[:blocking_job].slug)
            render json: { message: message }
            return
          end

          unless status[:can_request]
            render_error("validation_failed", main_branch_repair_blocked_message(status, repository), status: :unprocessable_content)
            return
          end

          job = service.ensure_repair_job!(force: true)
          if job
            message = I18n.t("api.repositories.main_branch_repair_enqueued", slug: job.slug)
            render json: { message: message }
          else
            render_error("validation_failed", I18n.t("api.repositories.main_branch_repair_not_created", slug: repository.slug), status: :unprocessable_content)
          end
        end

        def check_ci_now
          return unless (repository = find_repository_for_admin_mutation)
          if repository.archived?
            render_error("validation_failed", I18n.t("api.repositories.archived_first", slug: repository.slug), status: :unprocessable_content)
            return
          end

          if repository.ci_health_not_configured?
            render_error("validation_failed", I18n.t("api.repositories.ci_not_configured", slug: repository.slug), status: :unprocessable_content)
            return
          end

          PollMainBranchHealthJob.perform_later(repository.id, manual: true)
          message = I18n.t("api.repositories.check_ci_now_enqueued", slug: repository.slug)
          render json: { message: message }
        end

        private

        def find_repository
          Repository.accessible_to(Current.user).find(params[:id])
        end

        def find_repository_for_admin_mutation
          repository = find_repository
          repository if authorize_repository_admin!(repository)
        end

        def health_history_json(repository)
          checks = repository.main_branch_health_checks.recent.limit(30).to_a
          workflow_paths = health_check_workflow_paths(checks)
          current_health = current_health_history_json(repository, checks)
          {
            ci_health: current_health[:ci_health],
            grader_health: current_health[:grader_health],
            main_health: current_health[:main_health],
            landing_paused: repository.main_branch_health_enabled? && repository.landing_paused?,
            main_branch_health_enabled: repository.main_branch_health_enabled?,
            main_branch_repair_enabled: repository.main_branch_health_enabled? && repository.main_branch_repair_enabled?,
            main_branch_repair_blocks_work: repository.main_branch_health_enabled? && repository.main_branch_repair_blocks_work?,
            main_branch_repair_auto_approve: repository.main_branch_repair_auto_approve?,
            treat_grader_timeouts_as_failures: repository.treat_grader_timeouts_as_failures?,
            last_health_checked_sha: repository.last_health_checked_sha,
            ci_signal_current: current_health[:ci_signal_current],
            grader_signal_current: current_health[:grader_signal_current],
            current_health_pending: current_health[:current_health_pending],
            current_ci_failed_checks: current_health[:current_ci_failed_checks],
            current_grader_failed_names: current_health[:current_grader_failed_names],
            main_branch_repair: main_branch_repair_json(repository),
            records: checks.map { |check| health_check_json(check, repository, workflow_paths: workflow_paths) }
          }
        end

        def current_health_history_json(repository, checks)
          unless repository.main_branch_health_enabled?
            return {
              ci_health: "unknown",
              grader_health: "unknown",
              main_health: "unknown",
              ci_signal_current: false,
              grader_signal_current: false,
              current_health_pending: false,
              current_ci_failed_checks: [],
              current_grader_failed_names: []
            }
          end

          sha = repository.last_health_checked_sha.to_s.presence
          ci_signal_current = sha.present? && (repository.last_ci_evaluated_sha == sha || repository.ci_health_not_configured?)
          grader_signal_current = sha.present? && repository.last_graded_sha == sha
          ci_health = ci_signal_current ? repository.ci_health : "unknown"
          grader_health = grader_signal_current ? repository.grader_health : "unknown"
          current_checks = sha ? checks.select { |check| check.sha == sha } : []

          {
            ci_health: ci_health,
            grader_health: grader_health,
            main_health: display_main_health(repository, ci_health, grader_health),
            ci_signal_current: ci_signal_current,
            grader_signal_current: grader_signal_current,
            current_health_pending: repository.main_branch_health_enabled? && (!ci_signal_current || !grader_signal_current),
            current_ci_failed_checks: current_checks.flat_map { |check| check.ci_failed_checks || [] }.uniq,
            current_grader_failed_names: current_checks.flat_map { |check| check.grader_failed_names || [] }.uniq
          }
        end

        def display_main_health(repository, ci_health, grader_health)
          return "unknown" unless repository.main_branch_health_enabled?
          return "broken" if ci_health == "broken" || grader_health == "broken"
          return "healthy" if grader_health == "healthy" && %w[ healthy not_configured ].include?(ci_health)
          return "inconclusive" if ci_health == "inconclusive" || grader_health == "inconclusive"

          "unknown"
        end




        def main_branch_repair_json(repository)
          unless repository.main_branch_health_enabled? && repository.main_branch_repair_enabled? && repository.main_health_broken?
            return {
              enabled: repository.main_branch_health_enabled? && repository.main_branch_repair_enabled?,
              failed_open_jobs_count: 0,
              max_open_failed_jobs: MainHealthChangedService::MAX_OPEN_FAILED_FIX_JOBS,
              blocked_reason: nil,
              can_request: false,
              can_spawn: false,
              blocking_job: nil,
              failed_jobs: []
            }
          end

          status = MainHealthChangedService.new(repository).repair_status
          {
            enabled: status[:enabled],
            failed_open_jobs_count: status[:failed_open_jobs_count],
            max_open_failed_jobs: status[:max_open_failed_jobs],
            blocked_reason: status[:blocked_reason],
            can_request: status[:can_request],
            can_spawn: status[:can_spawn],
            blocking_job: repair_job_json(status[:blocking_job]),
            failed_jobs: status[:failed_jobs].map { |job| repair_job_json(job) }
          }
        end

        def repair_job_json(job)
          return nil unless job

          {
            id: job.id,
            slug: job.slug,
            state: job.state,
            title: job.title,
            job_path: job_path(job)
          }
        end

        def health_check_workflow_paths(checks)
          workflow_ids = checks.filter_map(&:workflow_id).uniq
          return {} if workflow_ids.empty?

          workflows_by_id = Workflow
            .where(id: workflow_ids)
            .select(:id, :job_id)
            .index_by(&:id)

          workflows_by_id.transform_values do |workflow|
            "/jobs/#{workflow.job_id}?tab=workflows#workflow-#{workflow.id}"
          end
        end

        def health_check_json(check, repository, workflow_paths: {})
          sha_url = "https://github.com/#{repository.slug}/commit/#{check.sha}"
          {
            id: check.id,
            sha: check.sha.to_s[0, 7],
            sha_url: sha_url,
            checked_at: check.checked_at.iso8601,
            ci_health: check.ci_health,
            grader_health: check.grader_health,
            source: check.source,
            ci_failed_checks: check.ci_failed_checks || [],
            grader_failed_names: check.grader_failed_names || [],
            workflow_path: check.workflow_id ? workflow_paths[check.workflow_id] : nil
          }
        end

        def main_branch_repair_blocked_message(status, repository)
          case status[:blocked_reason]
          when "failed_open_cap"
            I18n.t(
              "api.repositories.main_branch_repair_failed_cap",
              count: status[:failed_open_jobs_count],
              max: status[:max_open_failed_jobs],
              slug: repository.slug
            )
          when "waiting"
            I18n.t("api.repositories.main_branch_repair_waiting", slug: repository.slug)
          when "active"
            I18n.t("api.repositories.main_branch_repair_active", slug: repository.slug)
          else
            I18n.t("api.repositories.main_branch_repair_unavailable", slug: repository.slug)
          end
        end
      end
    end
  end
end
