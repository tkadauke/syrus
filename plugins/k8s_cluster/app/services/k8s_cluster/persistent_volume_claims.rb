module K8sCluster
  # PersistentVolumeClaim is a namespaced kind (PersistentVolume, its
  # cluster-scoped counterpart, is out of scope for this Job).
  class PersistentVolumeClaims < ResourceService
    MAX_PVCS = 1_000

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_persistent_volume_claims(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_PVCS,
          persistent_volume_claims: items.first(MAX_PVCS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, persistent_volume_claim: client.get_persistent_volume_claim(name, namespace) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        status: item.dig("status", "phase"),
        capacity: item.dig("status", "capacity", "storage"),
        storage_class: item.dig("spec", "storageClassName"),
        access_modes: item.dig("spec", "accessModes") || [],
        volume_name: item.dig("spec", "volumeName"),
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
