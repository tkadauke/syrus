module Api
  module V1
    module App
      module Admin
        class GithubApiUsageController < BaseController
          def show
            return render json: { error: "github_source_plugin_disabled" }, status: :not_found unless SyrusGithubSource.enabled?

            render json: GithubSource::ApiUsagePayload.new(
              params: params,
              include_filter_schema: !ActiveModel::Type::Boolean.new.cast(params[:omit_filter_schema])
            ).as_json
          end
        end
      end
    end
  end
end
