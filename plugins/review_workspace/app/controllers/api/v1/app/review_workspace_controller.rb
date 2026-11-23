module Api
  module V1
    module App
      class ReviewWorkspaceController < Syrus::Host::AppController
        before_action :require_review_workspace_enabled

        def index
          render json: ReviewWorkspacePlugin::Payload.call(user: Syrus::Host::Current.user, scope: reviewable_job_scope)
        end

        def count
          render json: { count: ReviewWorkspacePlugin::EligibleJobs.call(user: Syrus::Host::Current.user, scope: reviewable_job_scope).length }
        end

        private

        def reviewable_job_scope
          policy_scope(Syrus::Host::JobRecord)
        end

        def require_review_workspace_enabled
          return if ::ReviewWorkspacePlugin.enabled?

          render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "review_workspace"), status: :not_found)
        end
      end
    end
  end
end
