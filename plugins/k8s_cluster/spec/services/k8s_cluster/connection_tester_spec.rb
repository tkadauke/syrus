require "rails_helper"

RSpec.describe K8sCluster::ConnectionTester do
  def fake_connection(response)
    double = instance_double(Faraday::Connection, headers: {}, get: response)
    allow(double).to receive(:get).with("/version").and_return(response)
    double
  end

  around do |example|
    original = described_class.connection_factory
    example.run
  ensure
    described_class.connection_factory = original
  end

  it "reports success when the API server responds successfully" do
    response = instance_double(Faraday::Response, success?: true)
    described_class.connection_factory = ->(*) { fake_connection(response) }

    result = described_class.test_params(api_server_url: "https://k8s.example.com:6443", token: "abc123")

    expect(result).to eq(success: true)
  end

  it "reports failure with the HTTP status when the API server returns an error" do
    response = instance_double(Faraday::Response, success?: false, status: 403)
    described_class.connection_factory = ->(*) { fake_connection(response) }

    result = described_class.test_params(api_server_url: "https://k8s.example.com:6443", token: "wrong")

    expect(result).to eq(success: false, error: "Kubernetes API returned HTTP 403")
  end

  it "reports failure with the driver's error message and does not raise" do
    described_class.connection_factory = ->(*) { raise Faraday::ConnectionFailed, "connection refused" }

    result = described_class.test_params(api_server_url: "https://k8s.example.com:6443", token: "abc123")

    expect(result).to eq(success: false, error: "connection refused")
  end

  it "sets the Authorization header from the bearer token" do
    response = instance_double(Faraday::Response, success?: true)
    connection = fake_connection(response)
    headers = {}
    allow(connection).to receive(:headers).and_return(headers)
    described_class.connection_factory = ->(*) { connection }

    described_class.test_params(api_server_url: "https://k8s.example.com:6443", token: "abc123")

    expect(headers["Authorization"]).to eq("Bearer abc123")
  end

  it "builds SSL client-cert options from decoded certificate and key data" do
    response = instance_double(Faraday::Response, success?: true)
    received_ssl_options = nil
    described_class.connection_factory = lambda { |_url, ssl_options|
      received_ssl_options = ssl_options
      fake_connection(response)
    }
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = build_self_signed_cert_with(key)

    described_class.test_params(
      api_server_url: "https://k8s.example.com:6443",
      client_cert: Base64.strict_encode64(certificate.to_pem),
      client_key: Base64.strict_encode64(key.to_pem)
    )

    expect(received_ssl_options[:client_cert]).to be_a(OpenSSL::X509::Certificate)
    expect(received_ssl_options[:client_key]).to be_a(OpenSSL::PKey::RSA)
    expect(received_ssl_options[:verify]).to be(true)
  end

  it "disables verification when insecure_skip_tls_verify is set" do
    response = instance_double(Faraday::Response, success?: true)
    received_ssl_options = nil
    described_class.connection_factory = lambda { |_url, ssl_options|
      received_ssl_options = ssl_options
      fake_connection(response)
    }

    described_class.test_params(api_server_url: "https://k8s.example.com:6443", token: "abc123", insecure_skip_tls_verify: true)

    expect(received_ssl_options[:verify]).to be(false)
  end

  it "builds the connection from a persisted cluster's decrypted credentials" do
    cluster = Factories.kubernetes_cluster(api_server_url: "https://cluster.internal:6443")
    cluster.token = "s3cret-token"
    cluster.save!
    response = instance_double(Faraday::Response, success?: true)
    received_url = nil
    described_class.connection_factory = lambda { |url, _ssl_options|
      received_url = url
      fake_connection(response)
    }

    described_class.test(cluster)

    expect(received_url).to eq("https://cluster.internal:6443")
  end

  def build_self_signed_cert_with(key)
    name = OpenSSL::X509::Name.parse("/CN=test")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = name
    cert.issuer = name
    cert.public_key = key.public_key
    cert.not_before = Time.now
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert
  end
end
