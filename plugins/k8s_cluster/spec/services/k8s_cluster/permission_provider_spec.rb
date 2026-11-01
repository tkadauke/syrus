require "rails_helper"

RSpec.describe K8sCluster::PermissionProvider do
  it "separates observation, secrets, workloads, node administration, and raw authority" do
    capabilities = described_class.permission_capability_descriptors.group_by(&:capability)

    expect(capabilities.keys).to contain_exactly(
      "k8s.observe@v1", "k8s.secret_access@v1", "k8s.workload_operations@v1",
      "k8s.node_administration@v1", "k8s.raw@v1"
    )
    expect(capabilities.fetch("k8s.observe@v1").map(&:operation)).to include("k8s.pod/read@v1")
    expect(capabilities.fetch("k8s.workload_operations@v1").map(&:operation)).to contain_exactly(
      "k8s.deployment/restart@v1", "k8s.deployment/scale@v1", "k8s.pod/delete@v1"
    )
  end

  it "uses job and session ceilings only for observation and secret metadata" do
    observe = described_class.capability_descriptor("k8s.pod/read@v1")
    secrets = described_class.capability_descriptor("k8s.secret/read@v1")
    workload = described_class.capability_descriptor("k8s.deployment/restart@v1")
    node = described_class.capability_descriptor("k8s.node/cordon@v1")
    raw = described_class.capability_descriptor("k8s.raw/execute@v1")

    expect(observe).to have_attributes(maximum_autonomy: :job, authority_durations: %i[invocation chat_session job])
    expect(secrets).to have_attributes(maximum_autonomy: :chat_session, authority_durations: %i[invocation chat_session])
    expect([ workload, node, raw ]).to all(have_attributes(maximum_autonomy: :invocation, authority_durations: [ :invocation ]))
    expect(described_class.permission_capability_descriptors).to all(satisfy { |descriptor| descriptor.defaults.values.uniq == [ :ask ] })
  end

  it "compares cluster, namespace, kind, and object scopes hierarchically" do
    schema = described_class.permission_resource_scopes.fetch(:pod)
    context = {}
    global = schema.normalize({}, context:).value
    cluster = schema.normalize({ cluster_id: 7 }, context:).value
    namespace = schema.normalize({ cluster_id: 7, namespace: "web" }, context:).value
    object = schema.normalize({ cluster_id: 7, namespace: "web", name: "web-123" }, context:).value

    expect(schema.compare(global, cluster, context:).value).to eq(:broader)
    expect(schema.compare(cluster, namespace, context:).value).to eq(:broader)
    expect(schema.compare(object, namespace, context:).value).to eq(:narrower)
    expect(schema.compare(object, { cluster_id: 8 }, context:).value).to eq(:disjoint)
    expect(object).to include("kind" => "pod", "name" => "web-123")
  end

  it "scopes raw kubectl authority by credential or cluster and redacts sensitive invocation data" do
    descriptor = described_class.capability_descriptor("k8s.raw/execute@v1")
    schema = descriptor.resource_scope

    expect(schema.normalize({ credential: "production", namespace: "web" }, context: {}).value)
      .to include("cluster_id" => "production", "namespace" => "web", "kind" => "raw")
    expect(descriptor.redact(credential: "production", args: %w[get pods], namespace: "web"))
      .to eq("credential" => "[REDACTED CREDENTIAL]", "namespace" => "web", "args" => "[REDACTED KUBECTL ARGUMENTS]")
  end

  it "normalizes exact invocation fingerprints without retaining unrelated arguments" do
    descriptor = described_class.capability_descriptor("k8s.deployment/scale@v1")
    first = Permissions::InvocationFingerprint.call(
      descriptor:, arguments: { cluster_id: "7", namespace: "web", name: "api", replicas: 3, ignored: "value" }
    )
    second = Permissions::InvocationFingerprint.call(
      descriptor:, arguments: { name: "api", namespace: "web", replicas: 3, cluster_id: "7" }
    )

    expect(first).to eq(second)
  end
end
