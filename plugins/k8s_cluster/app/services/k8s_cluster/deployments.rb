module K8sCluster
  class Deployments < ResourceService
    MAX_DEPLOYMENTS = 1_000

    def list(namespace: nil)
      with_client(api_client.apps) do |client|
        items = client.get_deployments(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_DEPLOYMENTS,
          deployments: items.first(MAX_DEPLOYMENTS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.apps) do |client|
        { available: true, generated_at: Time.current.iso8601, deployment: client.get_deployment(name, namespace) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        replicas: integer(item.dig("spec", "replicas")),
        ready_replicas: integer(item.dig("status", "readyReplicas")).to_i,
        available_replicas: integer(item.dig("status", "availableReplicas")).to_i,
        updated_replicas: integer(item.dig("status", "updatedReplicas")).to_i,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
