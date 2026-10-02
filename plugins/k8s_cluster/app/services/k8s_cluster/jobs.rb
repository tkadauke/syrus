module K8sCluster
  class Jobs < ResourceService
    MAX_JOBS = 1_000

    def list(namespace: nil)
      with_client(api_client.batch) do |client|
        items = client.get_jobs(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_JOBS,
          jobs: items.first(MAX_JOBS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.batch) do |client|
        { available: true, generated_at: Time.current.iso8601, job: client.get_job(name, namespace) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        completions: integer(item.dig("spec", "completions")),
        parallelism: integer(item.dig("spec", "parallelism")),
        active_count: active_count(item.dig("status", "active")),
        succeeded: integer(item.dig("status", "succeeded")).to_i,
        failed: integer(item.dig("status", "failed")).to_i,
        selector: item.dig("spec", "selector", "matchLabels") || {},
        conditions: recent_conditions(item),
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end

    def recent_conditions(item)
      (item.dig("status", "conditions") || []).last(3).map do |condition|
        {
          type: condition["type"],
          status: condition["status"],
          reason: condition["reason"],
          last_transition_time: condition["lastTransitionTime"]
        }
      end
    end

    # `.status.active` is an integer count on a real API server, but tolerate
    # an array shape as well so list-shaped payloads still count correctly.
    def active_count(value)
      return value.length if value.is_a?(Array)

      integer(value).to_i
    end
  end
end
