module Api
  module V1
    module Admin
      # Read-only admin lookup for ScheduledTasks::CronTemplate. Authoring
      # stays in the SPA (Api::V1::App::CronTemplatesController); this exists
      # so an operator inspecting a paused/misbehaving scheduled task can also
      # see the template it was built from without a session cookie.
      #
      #   GET /api/v1/admin/cron_templates
      #   GET /api/v1/admin/cron_templates/:id
      class CronTemplatesController < BaseController
        before_action :require_scheduled_tasks_enabled

        # ?user substring match against User#email_address
        def index
          templates = ::ScheduledTasks::CronTemplate.includes(:user).order(:name)
          if params[:user].present?
            templates = templates.joins(:user).where("users.email_address LIKE ?", "%#{params[:user]}%")
          end

          render json: { count: templates.size, cron_templates: templates.map { |template| template_json(template) } }
        end

        def show
          template = ::ScheduledTasks::CronTemplate.find(params[:id])
          render json: template_detail_json(template)
        end

        private

        def require_scheduled_tasks_enabled
          return if ::ScheduledTasks.enabled?

          render_error("plugin_disabled", "The scheduled_tasks plugin is disabled.", status: :not_found)
        end

        def template_json(template)
          {
            id: template.id,
            user_id: template.user_id,
            user_email: template.user.email_address,
            name: template.name,
            description: template.description,
            cron_expression: template.cron_expression,
            schedule_expression: template.schedule_expression,
            schedule_explanation: template.schedule_explanation,
            schedule_timezone: template.schedule_timezone,
            pr_pileup_policy: template.pr_pileup_policy,
            enabled: template.enabled?,
            applied_tasks_count: template.scheduled_tasks.alive.count,
            next_fire_at: template.next_fire_at&.iso8601,
            created_at: template.created_at,
            updated_at: template.updated_at
          }
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(template, e)
        end

        def template_detail_json(template)
          template_json(template).merge(prompt: template.prompt)
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(template, e)
        end
      end
    end
  end
end
