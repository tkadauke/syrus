require "rails_helper"

RSpec.describe KubernetesCluster do
  it "requires label and api_server_url" do
    cluster = KubernetesCluster.new

    expect(cluster).not_to be_valid
    expect(cluster.errors[:label]).to be_present
    expect(cluster.errors[:api_server_url]).to be_present
  end

  it "defaults agentic_access_enabled, allow_writes, and insecure_skip_tls_verify to false" do
    cluster = Factories.kubernetes_cluster

    expect(cluster.agentic_access_enabled).to be false
    expect(cluster.allow_writes).to be false
    expect(cluster.insecure_skip_tls_verify).to be false
  end

  describe "credential encryption" do
    it "round-trips a bearer token through the encrypted credentials column" do
      cluster = Factories.kubernetes_cluster
      cluster.token = "s3cret-token"
      cluster.save!

      reloaded = KubernetesCluster.find(cluster.id)
      expect(reloaded.token).to eq("s3cret-token")
    end

    it "round-trips client certificate credentials through the encrypted credentials column" do
      cluster = Factories.kubernetes_cluster
      cluster.client_cert = "cert-data"
      cluster.client_key = "key-data"
      cluster.ca_data = "ca-data"
      cluster.save!

      reloaded = KubernetesCluster.find(cluster.id)
      expect(reloaded.client_cert).to eq("cert-data")
      expect(reloaded.client_key).to eq("key-data")
      expect(reloaded.ca_data).to eq("ca-data")
    end

    it "never stores plaintext credentials in the raw database column" do
      cluster = Factories.kubernetes_cluster
      cluster.token = "s3cret-token"
      cluster.save!

      raw_value = ActiveRecord::Base.connection.select_value(
        "SELECT credentials FROM kubernetes_clusters WHERE id = #{cluster.id}"
      )

      expect(raw_value.to_s).not_to include("s3cret-token")
    end

    it "defaults credentials to an empty hash" do
      cluster = KubernetesCluster.new
      expect(cluster.credentials).to eq({})
      expect(cluster.token).to be_nil
      expect(cluster.client_cert).to be_nil
    end
  end
end
