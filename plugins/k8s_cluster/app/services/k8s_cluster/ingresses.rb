module K8sCluster
  # The Kubernetes Ingress resource kind (external HTTP(S) routing into
  # Services), served by the networking.k8s.io API group. List rows carry
  # hosts, path rules with their backend Service/port, TLS hosts, and the
  # ingress class so operators can trace an external URL to its backing
  # Service; describe returns the raw object.
  class Ingresses < ResourceService
    MAX_INGRESSES = 1_000

    def list(namespace: nil)
      with_client(api_client.networking) do |client|
        items = client.get_ingresses(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_INGRESSES,
          ingresses: items.first(MAX_INGRESSES).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.networking) do |client|
        { available: true, generated_at: Time.current.iso8601, ingress: client.get_ingress(name, namespace) }
      end
    end

    private

    def summary(item)
      rules = item.dig("spec", "rules") || []

      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        ingress_class: item.dig("spec", "ingressClassName"),
        hosts: rules.filter_map { |rule| rule["host"] },
        rules: rules.map { |rule| rule_summary(rule) },
        tls_hosts: (item.dig("spec", "tls") || []).flat_map { |tls| tls["hosts"] || [] }.uniq,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end

    def rule_summary(rule)
      {
        host: rule["host"],
        paths: ((rule.dig("http", "paths")) || []).map do |path|
          {
            path: path["path"],
            path_type: path["pathType"],
            service_name: path.dig("backend", "service", "name"),
            service_port: path.dig("backend", "service", "port", "number") || path.dig("backend", "service", "port", "name")
          }
        end
      }
    end
  end
end
