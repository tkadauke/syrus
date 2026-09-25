module K8sCluster
  # The Kubernetes Secret resource kind, redacted server-side: both list
  # and describe return metadata only (name, namespace, type, key names,
  # key count, created_at). Secret data values - base64-encoded in the
  # API response's `data` map - are never extracted, so they can appear
  # in no payload, log line, or tool response built from these methods.
  # AgenticAudit already logs only result byte sizes rather than payloads,
  # which keeps the audit trail redacted for this kind by construction.
  class Secrets < ResourceService
    MAX_SECRETS = 1_000

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_secrets(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_SECRETS,
          secrets: items.first(MAX_SECRETS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.core) do |client|
        item = client.get_secret(name, namespace)

        { available: true, generated_at: Time.current.iso8601, secret: summary(item) }
      end
    end

    private

    def summary(item)
      key_names = ((item["data"] || {}).keys).uniq.sort

      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        type: item["type"],
        key_count: key_names.length,
        key_names: key_names,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
