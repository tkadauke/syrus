module K8sCluster
  # The Kubernetes ConfigMap resource kind: namespaced key/value
  # configuration consumed by workloads. List rows carry key metadata
  # only (names + count); describe returns the raw object, whose `data`
  # values are plain, non-secret configuration.
  class ConfigMaps < ResourceService
    MAX_CONFIG_MAPS = 1_000

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_config_maps(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_CONFIG_MAPS,
          config_maps: items.first(MAX_CONFIG_MAPS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, config_map: client.get_config_map(name, namespace) }
      end
    end

    private

    def summary(item)
      key_names = self.class.key_names(item)

      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        key_count: key_names.length,
        key_names: key_names,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end

    def self.key_names(item)
      ((item["data"] || {}).keys + (item["binaryData"] || {}).keys).uniq.sort
    end
  end
end
