require "rails_helper"

RSpec.describe K8sCluster::PodLogsTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, name: "web-1", namespace: "default", container: nil, tail_lines: nil, previous: false, timestamps: false)
    described_class.call(
      server_context: {},
      cluster_id: cluster_id,
      name: name,
      namespace: namespace,
      container: container,
      tail_lines: tail_lines,
      previous: previous,
      timestamps: timestamps
    )
  end

  it "fetches the pod's log tail with the default tail_lines" do
    payload = { available: true, log: "line one\n" }
    service = instance_double(K8sCluster::Pods, logs: payload)
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(service).to have_received(:logs).with("web-1", namespace: "default", container: nil, tail_lines: 200, previous: false, timestamps: false)
  end

  it "passes through container, tail_lines, previous, and timestamps" do
    payload = { available: true, log: "sidecar logs\n" }
    service = instance_double(K8sCluster::Pods, logs: payload)
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    call(cluster_id: cluster.id, container: "sidecar", tail_lines: 50, previous: true, timestamps: true)

    expect(service).to have_received(:logs).with("web-1", namespace: "default", container: "sidecar", tail_lines: 50, previous: true, timestamps: true)
  end

  it "returns an error response when the pod cannot be reached" do
    service = instance_double(K8sCluster::Pods)
    allow(service).to receive(:logs).and_raise(K8sCluster::ResourceService::Unavailable, "502")
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("502")
  end

  it "refuses when the cluster has agentic access disabled" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = call(cluster_id: disabled.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
