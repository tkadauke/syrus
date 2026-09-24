module K8sCluster
  class DaemonSets < ResourceService
    MAX_DAEMON_SETS = 1_000

    def list(namespace: nil)
      with_client(api_client.apps) do |client|
        items = client.get_daemon_sets(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_DAEMON_SETS,
          daemon_sets: items.first(MAX_DAEMON_SETS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.apps) do |client|
        { available: true, generated_at: Time.current.iso8601, daemon_set: client.get_daemon_set(name, namespace) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        desired_number_scheduled: integer(item.dig("status", "desiredNumberScheduled")).to_i,
        current_number_scheduled: integer(item.dig("status", "currentNumberScheduled")).to_i,
        number_ready: integer(item.dig("status", "numberReady")).to_i,
        number_available: integer(item.dig("status", "numberAvailable")).to_i,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
