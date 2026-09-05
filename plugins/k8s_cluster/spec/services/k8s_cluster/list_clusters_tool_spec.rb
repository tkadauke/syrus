require "rails_helper"

RSpec.describe K8sCluster::ListClustersTool do
  it "returns only safe cluster metadata, including agentic and write flags" do
    enabled = Factories.kubernetes_cluster(
      label: "Production",
      api_server_url: "https://prod-k8s.internal:6443",
      token: "prod-secret",
      agentic_access_enabled: true,
      allow_writes: false
    )
    disabled = Factories.kubernetes_cluster(
      label: "Staging",
      api_server_url: "https://staging-k8s.internal:6443",
      token: "staging-secret",
      agentic_access_enabled: false,
      allow_writes: true
    )

    response = described_class.call(server_context: {})

    expect(response.error?).to be(false)
    payload = JSON.parse(response.content.first[:text])
    expect(payload.fetch("clusters")).to contain_exactly(
      {
        "id" => enabled.id,
        "label" => "Production",
        "agentic_access_enabled" => true,
        "allow_writes" => false,
        "created_at" => enabled.created_at.iso8601,
        "updated_at" => enabled.updated_at.iso8601
      },
      {
        "id" => disabled.id,
        "label" => "Staging",
        "agentic_access_enabled" => false,
        "allow_writes" => true,
        "created_at" => disabled.created_at.iso8601,
        "updated_at" => disabled.updated_at.iso8601
      }
    )

    serialized = response.content.first[:text]
    expect(serialized).not_to include("prod-secret")
    expect(serialized).not_to include("staging-secret")
    expect(serialized).not_to include("prod-k8s.internal")
  end
end
