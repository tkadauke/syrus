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
        active_count: integer(item.dig("status", "active")).to_i,
        succeeded: integer(item.dig("status", "succeeded")).to_i,
        failed: integer(item.dig("status", "failed")).to_i,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
