module Api
  module V1
    module App
      # Deliberately not namespaced under Api::V1::App::Repositories: that
      # module would shadow the top-level ::Repositories namespace for every
      # sibling controller, which silently breaks unrelated lookups like
      # Repositories::PluginRepoTabsPayload. Core's own repository-scoped
      # controllers use this flat naming for the same reason.
      class RepositoryThroughputController < BaseController
        def show
          repository = ::Repository.accessible_to(Current.user).find(params[:repository_id])

          payload = PerformanceLogging.phase("repository_throughput_metrics", repository_id: repository.id) do
            ::Throughput::MetricContract.new(repository: repository).call
          end

          render json: payload
        end
      end
    end
  end
end
