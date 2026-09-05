require "faraday"
require "openssl"
require "base64"

module K8sCluster
  # Attempts a lightweight, unauthenticated-shape GET against a cluster's
  # /version endpoint to prove the stored (or draft) connection info actually
  # reaches a Kubernetes API server. Never persists anything -- callers
  # decide separately whether to save a KubernetesCluster record.
  class ConnectionTester
    CONNECT_TIMEOUT_SECONDS = 5

    class_attribute :connection_factory, default: ->(api_server_url, ssl_options) {
      Faraday.new(url: api_server_url, ssl: ssl_options) do |f|
        f.options.timeout = CONNECT_TIMEOUT_SECONDS
        f.options.open_timeout = CONNECT_TIMEOUT_SECONDS
      end
    }

    def self.test(cluster)
      new.test(
        api_server_url: cluster.api_server_url,
        token: cluster.token,
        client_cert: cluster.client_cert,
        client_key: cluster.client_key,
        ca_data: cluster.ca_data,
        insecure_skip_tls_verify: cluster.insecure_skip_tls_verify
      )
    end

    def self.test_params(api_server_url:, token: nil, client_cert: nil, client_key: nil, ca_data: nil, insecure_skip_tls_verify: false)
      new.test(
        api_server_url: api_server_url,
        token: token,
        client_cert: client_cert,
        client_key: client_key,
        ca_data: ca_data,
        insecure_skip_tls_verify: insecure_skip_tls_verify
      )
    end

    def test(api_server_url:, token: nil, client_cert: nil, client_key: nil, ca_data: nil, insecure_skip_tls_verify: false)
      connection = build_connection(
        api_server_url: api_server_url,
        token: token,
        client_cert: client_cert,
        client_key: client_key,
        ca_data: ca_data,
        insecure_skip_tls_verify: insecure_skip_tls_verify
      )
      response = connection.get("/version")

      if response.success?
        { success: true }
      else
        { success: false, error: "Kubernetes API returned HTTP #{response.status}" }
      end
    rescue Faraday::Error, OpenSSL::OpenSSLError => e
      { success: false, error: e.message }
    end

    private

    def build_connection(api_server_url:, token:, client_cert:, client_key:, ca_data:, insecure_skip_tls_verify:)
      ssl_options = { verify: !insecure_skip_tls_verify }

      if client_cert.present? && client_key.present?
        ssl_options[:client_cert] = OpenSSL::X509::Certificate.new(Base64.decode64(client_cert))
        ssl_options[:client_key] = OpenSSL::PKey.read(Base64.decode64(client_key))
      end

      if ca_data.present?
        store = OpenSSL::X509::Store.new
        store.add_cert(OpenSSL::X509::Certificate.new(Base64.decode64(ca_data)))
        ssl_options[:cert_store] = store
      end

      self.class.connection_factory.call(api_server_url, ssl_options).tap do |connection|
        connection.headers["Authorization"] = "Bearer #{token}" if token.present?
      end
    end
  end
end
