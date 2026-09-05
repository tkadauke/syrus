module K8sCluster
  # The Kubernetes "Service" resource kind (Endpoints/networking), not to be
  # confused with this app/services/ directory.
  class Services < ResourceService
    MAX_SERVICES = 1_000

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_services(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_SERVICES,
          services: items.first(MAX_SERVICES).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, service: client.get_service(name, namespace) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        type: item.dig("spec", "type"),
        cluster_ip: item.dig("spec", "clusterIP"),
        external_ips: item.dig("spec", "externalIPs") || [],
        ports: (item.dig("spec", "ports") || []).map { |port| port_summary(port) },
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end

    def port_summary(port)
      { name: port["name"], port: integer(port["port"]), target_port: port["targetPort"], protocol: port["protocol"] }
    end
  end
end
