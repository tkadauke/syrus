module Api
  module V1
    module App
      class InsightScheduleConfigsController < BaseController
        before_action :require_agent_insights_feature

        def show
          repository = find_repository
          return unless repository

          config = repository.insight_schedule_config
          render json: config_json(config)
        end

        def update
          repository = find_repository
          return unless repository

          config = repository.insight_schedule_config || repository.build_insight_schedule_config

          config.assign_attributes(config_params)

          if config.save
            render json: { message: "Insight scheduling settings saved.", config: config_json(config) }
          else
            render_error("validation_failed", config.errors.full_messages.join("; "), status: :unprocessable_content)
          end
        end

        private

        def require_agent_insights_feature
          render_error("agent_insights_disabled", "Agent Insights is not enabled.", status: :forbidden) unless Feature.agent_insights_enabled?
        end

        def find_repository
          repo = Current.user.repositories.find_by(id: params[:id])
          render_error("not_found", "Repository not found.", status: :not_found) unless repo
          repo
        end

        def config_params
          params.permit(:enabled, :min_jobs_since_last_run, :max_jobs_since_last_run)
        end

        def config_json(config)
          if config
            {
              enabled: config.enabled,
              min_jobs_since_last_run: config.min_jobs_since_last_run,
              max_jobs_since_last_run: config.max_jobs_since_last_run
            }
          else
            {
              enabled: false,
              min_jobs_since_last_run: InsightScheduleConfig.column_defaults["min_jobs_since_last_run"] || 5,
              max_jobs_since_last_run: InsightScheduleConfig.column_defaults["max_jobs_since_last_run"] || 10
            }
          end
        end
      end
    end
  end
end
