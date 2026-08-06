module Api
  module V1
    module App
      class CronTemplatesController < BaseController
        def index
          templates = Current.user.cron_templates.order(:name)
          render json: {
            templates: templates.map { |template| template_index_json(template) },
            pr_pileup_policies: CronTemplate::PR_PILEUP_POLICIES
          }
        end

        def show
          template = find_template
          render json: template_detail_payload(template)
        end

        def create
          template = Current.user.cron_templates.build(cron_template_params)

          if template.save
            render json: template_detail_payload(template).merge(message: "Template created."), status: :created
          else
            render_error("validation_failed", template.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def update
          template = find_template

          if template.update(cron_template_params)
            render json: template_detail_payload(template).merge(message: "Template updated.")
          else
            render_error("validation_failed", template.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def preview_schedule
          result = Schedules::RecurringSchedule.preview(
            input: params[:schedule_input].presence || params[:cron_expression],
            structured_intent: params[:structured_intent]
          )

          render json: schedule_preview_json(result)
        end

        def destroy
          template = find_template
          template.destroy!

          templates = Current.user.cron_templates.order(:name)
          render json: {
            templates: templates.map { |row| template_index_json(row) },
            pr_pileup_policies: CronTemplate::PR_PILEUP_POLICIES,
            message: "Template deleted."
          }
        end

        private

        def find_template
          Current.user.cron_templates.find(params[:id])
        end

        def template_detail_payload(template)
          {
            template: template_detail_json(template),
            pr_pileup_policies: CronTemplate::PR_PILEUP_POLICIES,
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) },
            applied_tasks: template.scheduled_tasks.alive.includes(:repository).order(created_at: :desc).map { |task| task_json(task) }
          }
        end

        def template_index_json(template)
          {
            id: template.id,
            name: template.name,
            description: template.description,
            cron_expression: template.cron_expression,
            schedule_input: template.schedule_input,
            schedule_format: template.schedule_format,
            schedule_expression: template.schedule_expression,
            schedule_explanation: template.schedule_explanation,
            schedule_timezone: template.schedule_timezone,
            next_fire_at: template.next_fire_at&.iso8601,
            legacy_cron_expression: template.legacy_cron_expression,
            pr_pileup_policy: template.pr_pileup_policy,
            enabled: template.enabled?,
            applied_tasks_count: template.scheduled_tasks.alive.count,
            created_at: template.created_at.iso8601,
            updated_at: template.updated_at.iso8601
          }
        end

        def template_detail_json(template)
          template_index_json(template).merge(
            prompt: template.prompt
          )
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            new_scheduled_task_path: new_repository_scheduled_task_path(repository, from_template: params[:id])
          }
        end

        def task_json(task)
          {
            id: task.id,
            name: task.name,
            state: task.state,
            repository_id: task.repository_id,
            repository_slug: task.repository.slug,
            last_fired_at: task.last_fired_at&.iso8601,
            scheduled_task_path: scheduled_task_path(task),
            repository_path: repository_path(task.repository)
          }
        end

        def cron_template_params
          params.expect(cron_template: %i[ name description prompt cron_expression schedule_input schedule_expression schedule_timezone pr_pileup_policy enabled ])
        end

        def schedule_preview_json(result)
          {
            valid: result.valid?,
            schedule_input: result.input,
            schedule_format: result.format,
            schedule_expression: result.expression,
            schedule_timezone: result.timezone,
            schedule_explanation: result.explanation,
            next_fire_at: result.next_fire_at,
            cron_expression: result.cron_expression,
            errors: result.errors
          }
        end
      end
    end
  end
end
