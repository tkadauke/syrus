require "rails_helper"

RSpec.describe K8sCluster::ApiClient do
  def stub_client_factory
    received = []
    original = described_class.client_factory
    described_class.client_factory = lambda { |uri, version, options|
      received << { uri: uri, version: version, options: options }
      instance_double(Kubeclient::Client)
    }
    yield received
  ensure
    described_class.client_factory = original
  end

  it "builds the core client against the bare API server URL with version v1" do
    cluster = Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443/")

    stub_client_factory do |received|
      described_class.new(cluster).core

      expect(received.first[:uri]).to eq("https://k8s.example.com:6443")
      expect(received.first[:version]).to eq("v1")
      expect(received.first[:options][:as]).to eq(:parsed)
    end
  end

  it "builds the apps client against the apis/apps group path" do
    cluster = Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443")

    stub_client_factory do |received|
      described_class.new(cluster).apps

      expect(received.first[:uri]).to eq("https://k8s.example.com:6443/apis/apps")
      expect(received.first[:version]).to eq("v1")
    end
  end

  it "builds the batch client against the apis/batch group path" do
    cluster = Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443")

    stub_client_factory do |received|
      described_class.new(cluster).batch

      expect(received.first[:uri]).to eq("https://k8s.example.com:6443/apis/batch")
    end
  end

  it "builds the metrics client against the apis/metrics.k8s.io group path with version v1beta1" do
    cluster = Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443")

    stub_client_factory do |received|
      described_class.new(cluster).metrics

      expect(received.first[:uri]).to eq("https://k8s.example.com:6443/apis/metrics.k8s.io")
      expect(received.first[:version]).to eq("v1beta1")
    end
  end

  it "memoizes one client per API group per instance" do
    cluster = Factories.kubernetes_cluster
    api_client = described_class.new(cluster)

    stub_client_factory do |received|
      2.times { api_client.core }
      api_client.apps

      expect(received.count { |call| call[:version] == "v1" && call[:uri] == cluster.api_server_url }).to eq(1)
    end
  end

  it "passes the bearer token as an auth option" do
    cluster = Factories.kubernetes_cluster
    cluster.token = "abc123"
    cluster.save!

    stub_client_factory do |received|
      described_class.new(cluster).core

      expect(received.first[:options][:auth_options]).to eq(bearer_token: "abc123")
    end
  end

  it "omits auth options entirely when there is no token" do
    cluster = Factories.kubernetes_cluster

    stub_client_factory do |received|
      described_class.new(cluster).core

      expect(received.first[:options][:auth_options]).to eq({})
    end
  end

  it "builds client-cert SSL options from decoded certificate and key data" do
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = build_self_signed_cert_with(key)
    cluster = Factories.kubernetes_cluster
    cluster.client_cert = Base64.strict_encode64(certificate.to_pem)
    cluster.client_key = Base64.strict_encode64(key.to_pem)
    cluster.save!

    stub_client_factory do |received|
      described_class.new(cluster).core
      ssl_options = received.first[:options][:ssl_options]

      expect(ssl_options[:client_cert]).to be_a(OpenSSL::X509::Certificate)
      expect(ssl_options[:client_key]).to be_a(OpenSSL::PKey::RSA)
      expect(ssl_options[:verify_ssl]).to eq(OpenSSL::SSL::VERIFY_PEER)
    end
  end

  it "sets verify_ssl to VERIFY_NONE when insecure_skip_tls_verify is set" do
    cluster = Factories.kubernetes_cluster(insecure_skip_tls_verify: true)

    stub_client_factory do |received|
      described_class.new(cluster).core

      expect(received.first[:options][:ssl_options][:verify_ssl]).to eq(OpenSSL::SSL::VERIFY_NONE)
    end
  end

  it "builds a cert_store from CA data when present" do
    cluster = Factories.kubernetes_cluster
    cluster.ca_data = Base64.strict_encode64(build_self_signed_cert_with(OpenSSL::PKey::RSA.new(2048)).to_pem)
    cluster.save!

    stub_client_factory do |received|
      described_class.new(cluster).core

      expect(received.first[:options][:ssl_options][:cert_store]).to be_a(OpenSSL::X509::Store)
    end
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
