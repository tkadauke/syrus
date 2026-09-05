require "kubeclient"
require "openssl"
require "base64"

module K8sCluster
  # Builds authenticated Kubeclient::Client instances for a KubernetesCluster,
  # one per Kubernetes API group, translating the cluster's stored
  # credentials (bearer token, or client cert/key, either possibly paired
  # with CA data) into Kubeclient's ssl_options/auth_options shape - the same
  # credential fields ConnectionTester already knows how to turn into
  # OpenSSL objects, base64-decoded from the parsed kubeconfig.
  #
  # Every client is built with `as: :parsed` so entity calls (get_pods,
  # get_deployments, ...) return plain parsed JSON hashes/lists instead of
  # RecursiveOpenStruct wrappers - resource services just dig into hashes,
  # same as the rest of Syrus.
  class ApiClient
    CONNECT_TIMEOUT_SECONDS = 10

    CORE = { group_path: nil, version: "v1" }.freeze
    APPS = { group_path: "apis/apps", version: "v1" }.freeze
    BATCH = { group_path: "apis/batch", version: "v1" }.freeze
    METRICS = { group_path: "apis/metrics.k8s.io", version: "v1beta1" }.freeze

    class_attribute :client_factory, default: ->(uri, version, options) { Kubeclient::Client.new(uri, version, **options) }

    def initialize(cluster)
      @cluster = cluster
      @clients = {}
    end

    def core = @clients[:core] ||= build(**CORE)
    def apps = @clients[:apps] ||= build(**APPS)
    def batch = @clients[:batch] ||= build(**BATCH)
    def metrics = @clients[:metrics] ||= build(**METRICS)

    private

    attr_reader :cluster

    def build(group_path:, version:)
      base = cluster.api_server_url.to_s.chomp("/")
      uri = group_path.present? ? "#{base}/#{group_path}" : base

      self.class.client_factory.call(
        uri,
        version,
        ssl_options: ssl_options,
        auth_options: auth_options,
        timeouts: { open: CONNECT_TIMEOUT_SECONDS, read: CONNECT_TIMEOUT_SECONDS },
        as: :parsed
      )
    end

    def ssl_options
      options = { verify_ssl: cluster.insecure_skip_tls_verify ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER }

      if cluster.client_cert.present? && cluster.client_key.present?
        options[:client_cert] = OpenSSL::X509::Certificate.new(Base64.decode64(cluster.client_cert))
        options[:client_key] = OpenSSL::PKey.read(Base64.decode64(cluster.client_key))
      end

      options[:cert_store] = build_cert_store(cluster.ca_data) if cluster.ca_data.present?

      options
    end

    def build_cert_store(ca_data)
      store = OpenSSL::X509::Store.new
      store.add_cert(OpenSSL::X509::Certificate.new(Base64.decode64(ca_data)))
      store
    end

    def auth_options
      cluster.token.present? ? { bearer_token: cluster.token } : {}
    end
  end
end
