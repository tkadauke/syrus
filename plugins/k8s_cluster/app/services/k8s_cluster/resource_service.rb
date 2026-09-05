require "kubeclient"

module K8sCluster
  # Shared shape for the one-service-per-resource-kind split: every resource
  # service (Namespaces, Pods, Deployments, ...) wraps a cluster's ApiClient
  # and maps Kubeclient's exceptions - and the lower-level connection
  # failures Kubeclient doesn't itself normalize (timeouts, TLS failures,
  # DNS/connection errors) - onto the same two outcomes SchemaInspector uses
  # for MysqlDbBrowser: Unavailable (the cluster/API couldn't be reached) and
  # NotFound (the cluster was reached, but the named resource doesn't exist).
  class ResourceService
    class Unavailable < StandardError; end
    class NotFound < StandardError; end

    CONNECTION_ERRORS = [
      RestClient::Exceptions::Timeout,
      RestClient::ServerBrokeConnection,
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      SocketError,
      OpenSSL::SSL::SSLError
    ].freeze

    def initialize(cluster)
      @cluster = cluster
    end

    private

    attr_reader :cluster

    def api_client
      @api_client ||= ApiClient.new(cluster)
    end

    def with_client(client)
      yield client
    rescue Kubeclient::ResourceNotFoundError => e
      raise NotFound, e.message
    rescue Kubeclient::HttpError => e
      raise Unavailable, e.message
    rescue *CONNECTION_ERRORS => e
      raise Unavailable, e.message
    end

    def namespace_scope(namespace)
      namespace.presence ? { namespace: namespace } : {}
    end

    def integer(value)
      Integer(value, exception: false) if value
    end
  end
end
