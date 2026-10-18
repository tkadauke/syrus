module Api
  module V1
    module App
      # Deliberately not namespaced under Api::V1::App::Repositories: that
      # module would shadow the top-level ::Repositories namespace for every
      # sibling controller, which silently breaks unrelated lookups like
      # Repositories::PluginRepoTabsPayload. Core's own repository-scoped
      # controllers use this flat naming for the same reason.
      class RepositoryThroughputController < BaseController
        include RepositoryTabsSerialization

        def show
          repository = ::Repository.accessible_to(Current.user).find(params[:repository_id])

          payload = PerformanceLogging.phase("repository_throughput_metrics", repository_id: repository.id) do
            ::Throughput::RepositorySnapshot.new(repository: repository).read
          end

          render json: payload.merge(
            repository: repository_json(repository),
            tabs: repository_tabs_json(repository)
          )
        rescue ::Throughput::RepositorySnapshot::Unavailable => e
          render json: { error: "throughput_snapshot_unavailable", message: e.message }, status: :service_unavailable
        end

        private

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            github_url: "https://github.com/#{repository.slug}"
          }
        end
      end
    end
  end
end
