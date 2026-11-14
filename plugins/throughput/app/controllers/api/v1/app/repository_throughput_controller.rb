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

          window = params[:window].presence_in(::Throughput::MetricContract::WINDOW_DEFINITIONS.keys + [ "last_active" ]) || "4h"
          windows = payload[:windows] || payload["windows"] || {}
          selected_window = windows[window] || windows[window.to_sym]
          payload = payload.merge(windows: selected_window ? { window => slim_window(selected_window) } : {})

          fresh_when(etag: [ repository.id, payload[:generated_at] || payload["generated_at"], window ])
          return if request.fresh?(response)

          render json: payload.merge(
            repository: repository_json(repository),
            tabs: repository_tabs_json(repository)
          )
        rescue ::Throughput::RepositorySnapshot::Unavailable => e
          render json: { error: "throughput_snapshot_unavailable", message: e.message }, status: :service_unavailable
        end

        private

        def slim_window(window)
          window.deep_dup.tap do |result|
            delete_nested(result, "pr_creation", "series")
            delete_nested(result, "output", "by_job")
            delete_nested(result, "landing", "attempts")
            delete_nested(result, "landing", "merge_train_size", "values")
          end
        end

        def delete_nested(payload, *path)
          leaf = path[0...-1].reduce(payload) { |value, key| value&.[](key) || value&.[](key.to_sym) }
          leaf&.delete(path.last)
          leaf&.delete(path.last.to_sym)
        end

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
