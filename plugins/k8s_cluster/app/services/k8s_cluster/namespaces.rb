module K8sCluster
  # Cluster-scoped: namespaces have no namespace of their own.
  class Namespaces < ResourceService
    MAX_NAMESPACES = 1_000

    def list
      with_client(api_client.core) do |client|
        items = client.get_namespaces.fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_NAMESPACES,
          namespaces: items.first(MAX_NAMESPACES).map { |item| summary(item) }
        }
      end
    end

    def describe(name)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, namespace: client.get_namespace(name) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        status: item.dig("status", "phase"),
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
