module K8sCluster
  # The Kubernetes "Endpoints" resource kind: the actual ready/not-ready pod
  # IPs backing a Service. Namespace-scoped, and - by core v1 API convention -
  # shares its name with the Service it backs, so ServicesTab can pair a
  # Service row with its Endpoints row by (namespace, name) without a
  # separate lookup field. A Service with no selector (e.g. ExternalName)
  # has no matching Endpoints object; callers should treat a missing pairing
  # as "not applicable", not an error.
  class Endpoints < ResourceService
    MAX_ENDPOINTS = 1_000

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_endpoints(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_ENDPOINTS,
          endpoints: items.first(MAX_ENDPOINTS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, endpoint: client.get_endpoint(name, namespace) }
      end
    end

    private

    def summary(item)
      subsets = item["subsets"] || []

      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        ready_addresses: subsets.sum { |subset| (subset["addresses"] || []).length },
        not_ready_addresses: subsets.sum { |subset| (subset["notReadyAddresses"] || []).length },
        ports: subsets.flat_map { |subset| subset["ports"] || [] }.map { |port| port_summary(port) }.uniq,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end

    def port_summary(port)
      { name: port["name"], port: integer(port["port"]), protocol: port["protocol"] }
    end
  end
end
