module Api
  module V1
    module Admin
      # Operator-facing REST surface for ScheduledTasks::Task, so an incident
      # responder can inspect and pause/unpause/fire a schedule with a bearer
      # token instead of a browser session or a Rails console. Read paths and
      # the pause/unpause/fire actions all reuse the same model/service methods
      # the app API (Api::V1::App::ScheduledTasksController) already calls —
      # this controller only adds instance-wide (not per-user) scoping and JSON
      # shaping on top.
      #
      #   GET  /api/v1/admin/scheduled_tasks
      #   GET  /api/v1/admin/scheduled_tasks/:id
      #   POST /api/v1/admin/scheduled_tasks/:id/pause
      #   POST /api/v1/admin/scheduled_tasks/:id/unpause
      #   POST /api/v1/admin/scheduled_tasks/:id/fire
      class ScheduledTasksController < BaseController
        before_action :require_scheduled_tasks_enabled

        INDEX_LIMIT = 200

        # Filters (all optional, AND-composed):
        #   ?repository   "owner/name"
        #   ?user         substring match against User#email_address
        #   ?kind         cron|one_shot
        #   ?paused       true|false — paused/auto_paused vs. everything else
        #   ?due_before   ISO8601 — tasks whose next fire time falls before it
        #
        # No filters → most-recently updated 200, alive (non-archived) tasks.
        def index
          scope = ::ScheduledTasks::Task.alive.includes(:repository, :user).order(updated_at: :desc)
          scope = scope.where(kind: params[:kind]) if params[:kind].present?
          if params[:repository].present?
            owner, name = params[:repository].split("/", 2)
            scope = scope.joins(:repository).where(repositories: { owner: owner, name: name })
          end
          if params[:user].present?
            scope = scope.joins(:user).where("users.email_address LIKE ?", "%#{params[:user]}%")
          end
          if params[:paused].present?
            paused = truthy?(params[:paused])
            scope = paused ? scope.where(state: ::ScheduledTasks::Task::PAUSE_STATES.values) :
                              scope.where.not(state: ::ScheduledTasks::Task::PAUSE_STATES.values)
          end

          tasks = scope.limit(INDEX_LIMIT).to_a
          if params[:due_before].present? && (cutoff = parse_time(params[:due_before]))
            tasks = tasks.select { |task| (next_fire = task.next_fire_at) && next_fire <= cutoff }
          end

          render json: { count: tasks.size, scheduled_tasks: tasks.map { |task| task_json(task) } }
        end

        def show
          render json: task_detail_json(find_task)
        end

        def pause
          task = find_task
          task.pause!(reason: "operator")
          render json: task_detail_json(task.reload).merge(message: "Paused.")
        end

        def unpause
          task = find_task
          task.resume!
          render json: task_detail_json(task.reload).merge(message: "Resumed.")
        end

        def fire
          task = find_task
          if task.archived? || task.fired?
            return render_error("not_fireable", "Task isn't fireable in its current state.", status: :unprocessable_content)
          end

          result = ::ScheduledTasks::Fire.new(task).call
          message = result.fired? ? "Fired (#{result.job.slug})." : "Fire skipped: #{result.reason}."
          render json: task_detail_json(task.reload).merge(message: message, fire_result: fire_result_json(result))
        rescue StandardError => e
          Rails.logger.warn("[API Admin::ScheduledTasks#fire] task ##{task&.id}: #{e.class}: #{e.message}")
          render_error("fire_failed", "Fire failed: #{e.message}", status: :unprocessable_content)
        end

        private

        def require_scheduled_tasks_enabled
          return if ::ScheduledTasks.enabled?

          render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "scheduled_tasks"), status: :not_found)
        end

        def find_task
          ::ScheduledTasks::Task.find(params[:id])
        end

        def truthy?(value)
          %w[ true 1 yes ].include?(value.to_s.downcase)
        end

        def parse_time(value)
          Time.iso8601(value)
        rescue ArgumentError, TypeError
          nil
        end

        def task_json(task)
          {
            id: task.id,
            name: task.name,
            kind: task.kind,
            state: task.state,
            paused: task.paused? || task.auto_paused?,
            pause_reason: pause_reason(task),
            archived: task.archived?,
            repository: { id: task.repository.id, slug: task.repository.slug },
            user_id: task.user_id,
            user_email: task.user.email_address,
            cron_expression: task.hourly_cron_expression,
            schedule_expression: task.schedule_expression,
            schedule_explanation: task.schedule_explanation,
            schedule_timezone: task.schedule_timezone,
            fire_at: task.fire_at&.iso8601,
            pr_pileup_policy: task.pr_pileup_policy,
            consecutive_failure_count: task.consecutive_failure_count,
            last_fired_at: task.last_fired_at&.iso8601,
            last_successful_fire_at: task.last_successful_fire_at&.iso8601,
            next_fire_at: task.next_fire_at&.iso8601,
            skill_name: task.skill_name,
            cron_template_id: task.cron_template_id,
            created_at: task.created_at,
            updated_at: task.updated_at
          }
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(task, e)
        end

        def task_detail_json(task)
          task_json(task).merge(
            prompt: task.prompt,
            skill_args: task.skill_args || {},
            auto_approve_mode: task.auto_approve_mode,
            fireable: !task.archived? && !task.fired?,
            pausable: task.state == "scheduled",
            resumable: task.paused? || task.auto_paused?,
            recent_jobs: task.jobs.order(created_at: :desc).limit(10).map { |job| recent_job_json(job) }
          )
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(task, e)
        end

        def pause_reason(task)
          return "operator" if task.paused?
          return "auto" if task.auto_paused?
          nil
        end

        def recent_job_json(job)
          {
            id: job.id,
            slug: job.slug,
            state: job.state,
            closure_reason: job.closure_reason,
            pr_number: job.pr_number,
            external_pr_number: job.external_pr_number,
            created_at: job.created_at.iso8601
          }
        end

        def fire_result_json(result)
          {
            fired: result.fired?,
            skipped: result.skipped,
            reason: result.reason,
            job_id: result.job&.id
          }
        end
      end
    end
  end
end
