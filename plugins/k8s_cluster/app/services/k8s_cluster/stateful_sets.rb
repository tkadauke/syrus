module K8sCluster
  class StatefulSets < ResourceService
    MAX_STATEFUL_SETS = 1_000

    def list(namespace: nil)
      with_client(api_client.apps) do |client|
        items = client.get_stateful_sets(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_STATEFUL_SETS,
          stateful_sets: items.first(MAX_STATEFUL_SETS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.apps) do |client|
        { available: true, generated_at: Time.current.iso8601, stateful_set: client.get_stateful_set(name, namespace) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        replicas: integer(item.dig("spec", "replicas")),
        ready_replicas: integer(item.dig("status", "readyReplicas")).to_i,
        current_replicas: integer(item.dig("status", "currentReplicas")).to_i,
        updated_replicas: integer(item.dig("status", "updatedReplicas")).to_i,
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
  end
end
