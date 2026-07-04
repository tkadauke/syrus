module Api
  module V1
    module App
      class ScheduledTasksController < BaseController
        def index
          render json: scheduled_tasks_index_payload
        end

        def show
          task = find_task
          render json: scheduled_task_detail_payload(task)
        end

        def new
          repository = find_repository
          task = repository.scheduled_tasks.build(
            user: Current.user,
            kind: "cron",
            pr_pileup_policy: "skip"
          )
          from_template = nil

          if params[:from_template].present?
            from_template = Current.user.cron_templates.find_by(id: params[:from_template])
            assign_from_template(task, from_template) if from_template
          end

          render json: scheduled_task_form_payload(task, repository: repository, from_template: from_template)
        end

        def repository_index
          repository = find_repository
          render json: repository_scheduled_tasks_payload(repository)
        end

        def create
          repository = find_repository
          task = repository.scheduled_tasks.build(scheduled_task_params)
          task.user = Current.user
          if params[:from_template].present?
            template = Current.user.cron_templates.find_by(id: params[:from_template])
            task.cron_template = template if template
          end

          if task.save
            render json: scheduled_task_detail_payload(task).merge(message: "Scheduled task created."), status: :created
          else
            render_error("validation_failed", task.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def repository_update
          repository = find_repository
          task = find_repository_task(repository)
          enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
          if enabled
            task.resume!
            message = "Scheduled task enabled."
          else
            task.pause!(reason: "operator")
            message = "Scheduled task disabled."
          end

          render json: repository_scheduled_tasks_payload(repository).merge(message: message)
        end

        def repository_destroy
          repository = find_repository
          task = find_repository_task(repository)
          task.soft_delete!

          render json: repository_scheduled_tasks_payload(repository).merge(message: "Scheduled task deleted.")
        end

        def update
          task = find_task

          if task.update(scheduled_task_params)
            render json: scheduled_task_detail_payload(task).merge(message: "Scheduled task updated.")
          else
            render_error("validation_failed", task.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def destroy
          task = find_task
          task.soft_delete!

          render json: scheduled_tasks_index_payload.merge(message: "Scheduled task archived.")
        end

        def pause
          task = find_task
          task.pause!(reason: "operator")

          render json: scheduled_task_detail_payload(task.reload).merge(message: "Paused.")
        end

        def resume
          task = find_task
          task.resume!

          render json: scheduled_task_detail_payload(task.reload).merge(message: "Resumed.")
        end

        def fire_now
          task = find_task
          if task.archived? || task.fired?
            render_error("not_fireable", "Task isn't fireable in its current state.", status: :unprocessable_content)
            return
          end

          result = ScheduledTaskFire.new(task).call
          message = result.fired? ? "Fired (#{result.job.slug})." : "Fire skipped: #{result.reason}."
          render json: scheduled_task_detail_payload(task.reload).merge(message: message, fire_result: fire_result_json(result))
        rescue StandardError => e
          Rails.logger.warn("[API ScheduledTasks#fire_now] task ##{task&.id}: #{e.class}: #{e.message}")
          render_error("fire_failed", "Fire failed: #{e.message}", status: :unprocessable_content)
        end

        private

        def scheduled_tasks_index_payload
          tasks = ScheduledTask.alive.where(user: Current.user).includes(:repository)
          {
            active_tasks: tasks.where(state: %w[ scheduled paused auto_paused ]).order(:created_at).map { |task| task_summary_json(task) },
            fired_one_shots: tasks.where(state: "fired").order(updated_at: :desc).limit(20).map { |task| task_summary_json(task) },
            archived_tasks: ScheduledTask.archived.where(user: Current.user).includes(:repository).order(archived_at: :desc).limit(20).map { |task| task_summary_json(task) },
            options: scheduled_task_options
          }
        end

        def scheduled_task_detail_payload(task)
          {
            task: task_detail_json(task),
            recent_jobs: task.jobs.order(created_at: :desc).limit(20).map { |job| recent_job_json(job) },
            options: scheduled_task_options
          }
        end

        def scheduled_task_form_payload(task, repository:, from_template:)
          {
            task: task_form_json(task),
            repository: repository_json(repository),
            from_template: from_template ? cron_template_json(from_template) : nil,
            options: scheduled_task_options
          }
        end

        def repository_scheduled_tasks_payload(repository)
          tasks = repository
            .scheduled_tasks
            .alive
            .includes(:repository)
            .order(Arel.sql("CASE state WHEN 'scheduled' THEN 0 ELSE 1 END"), created_at: :desc)

          {
            repository: repository_json(repository),
            tabs: repository_tabs_json(repository),
            tasks: tasks.map { |task| repository_task_json(task) },
            new_scheduled_task_path: new_repository_scheduled_task_path(repository),
            options: scheduled_task_options
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

        def task_summary_json(task)
          {
            id: task.id,
            name: task.name,
            kind: task.kind,
            state: task.state,
            repository: repository_json(task.repository),
            schedule_label: schedule_label(task),
            next_fire_at: task.next_fire_at&.iso8601,
            last_fired_at: task.last_fired_at&.iso8601,
            archived_at: task.archived_at&.iso8601,
            consecutive_failure_count: task.consecutive_failure_count,
            scheduled_task_path: scheduled_task_path(task)
          }
        end

        def task_detail_json(task)
          task_summary_json(task).merge(
            prompt: task.prompt,
            cron_expression: task.cron_expression,
            hourly_cron_expression: task.hourly_cron_expression,
            fire_at: task.fire_at&.iso8601,
            next_fire_at: task.next_fire_at&.iso8601,
            pr_pileup_policy: task.pr_pileup_policy,
            auto_approve_mode: task.auto_approve_mode,
            auto_approve_preview: auto_approve_preview(task),
            last_successful_fire_at: task.last_successful_fire_at&.iso8601,
            archived: task.archived?,
            fireable: !task.archived? && !task.fired?,
            pausable: task.state == "scheduled",
            resumable: task.paused? || task.auto_paused?,
            editable: !task.archived?
          )
        end

        def repository_task_json(task)
          task_detail_json(task).merge(active: task.active?)
        end

        def task_form_json(task)
          {
            id: task.id,
            name: task.name,
            kind: task.kind,
            cron_expression: task.cron_expression,
            fire_at: task.fire_at&.iso8601,
            pr_pileup_policy: task.pr_pileup_policy,
            auto_approve_mode: task.auto_approve_mode,
            prompt: task.prompt,
            cron_template_id: task.cron_template_id
          }
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            repository_path: repository_path(repository)
          }
        end

        def cron_template_json(template)
          {
            id: template.id,
            name: template.name,
            cron_template_path: cron_template_path(template)
          }
        end

        def recent_job_json(job)
          {
            id: job.id,
            state: job.state,
            closure_reason: job.closure_reason,
            pr_number: job.pr_number,
            external_pr_number: job.external_pr_number,
            created_at: job.created_at.iso8601,
            job_path: job_path(job)
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

        def scheduled_task_options
          {
            kinds: ScheduledTask::KINDS,
            pr_pileup_policies: ScheduledTask::PR_PILEUP_POLICIES,
            auto_approve_modes: [
              { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
              { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." },
              { value: "if_graders_pass_and_tagged_safe", label: "If graders pass and tagged safe", preview: "Jobs using this rule also need the safe tag before landing." }
            ]
          }
        end

        def schedule_label(task)
          if task.cron?
            task.display_cron_expression
          else
            task.fire_at&.utc&.strftime("%Y-%m-%d %H:%M UTC")
          end
        end

        def auto_approve_preview(task)
          case task.auto_approve_mode
          when "if_graders_pass"
            "Jobs using this rule enter landing after repo-committed graders pass."
          when "if_graders_pass_and_tagged_safe"
            "Jobs using this rule also need the safe tag before landing."
          else
            "No direct rule; Jobs can still inherit a repository or user default."
          end
        end

        def assign_from_template(task, template)
          task.assign_attributes(
            name: template.name,
            prompt: template.prompt,
            cron_expression: template.cron_expression,
            pr_pileup_policy: template.pr_pileup_policy,
            cron_template: template
          )
        end

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def find_task
          ScheduledTask.where(user: Current.user).find(params[:id])
        end

        def find_repository_task(repository)
          repository.scheduled_tasks.find(params[:id])
        end

        def scheduled_task_params
          params.expect(scheduled_task: %i[ name prompt kind cron_expression fire_at pr_pileup_policy auto_approve_mode ])
        end
      end
    end
  end
end
