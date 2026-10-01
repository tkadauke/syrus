module K8sCluster
  # The Kubernetes "Service" resource kind (Endpoints/networking), not to be
  # confused with this app/services/ directory.
  class Services < ResourceService
    MAX_SERVICES = 1_000

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_services(namespace_scope(namespace)).fetch("items", [])
        endpoints_by_key = endpoints_by_key(client, namespace: namespace)

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_SERVICES,
          services: items.first(MAX_SERVICES).map { |item| summary(item, endpoints_by_key) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, service: client.get_service(name, namespace) }
      end
    end

    private

    def summary(item, endpoints_by_key)
      selector = item.dig("spec", "selector") || {}
      endpoint = endpoints_by_key.fetch(endpoint_key(item), nil)
      ready_addresses = endpoint&.fetch(:ready_addresses, 0)
      not_ready_addresses = endpoint&.fetch(:not_ready_addresses, 0)

      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        type: item.dig("spec", "type"),
        cluster_ip: item.dig("spec", "clusterIP"),
        external_ips: item.dig("spec", "externalIPs") || [],
        ports: (item.dig("spec", "ports") || []).map { |port| port_summary(port) },
        selector: selector,
        ready_addresses: ready_addresses,
        not_ready_addresses: not_ready_addresses,
        missing_target_warning: selector.present? && (endpoint.blank? || ready_addresses.to_i.zero?),
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end

    def endpoints_by_key(client, namespace:)
      items = client.get_endpoints(namespace_scope(namespace)).fetch("items", [])
      items.to_h { |item| [ endpoint_key(item), endpoint_summary(item) ] }
    end

    def endpoint_key(item)
      "#{item.dig("metadata", "namespace")}/#{item.dig("metadata", "name")}"
    end

    def endpoint_summary(item)
      subsets = item["subsets"] || []
      {
        ready_addresses: subsets.sum { |subset| (subset["addresses"] || []).length },
        not_ready_addresses: subsets.sum { |subset| (subset["notReadyAddresses"] || []).length }
      }
    end

    def port_summary(port)
      { name: port["name"], port: integer(port["port"]), target_port: port["targetPort"], protocol: port["protocol"] }
    end
  end
end
