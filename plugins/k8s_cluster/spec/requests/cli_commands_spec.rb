require "rails_helper"

RSpec.describe "Kubernetes CLI commands", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let!(:cluster) { Factories.kubernetes_cluster(label: "Production") }

  before { PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true) }

  def execute(path, flags: {}, args: [])
    post "/api/v1/app/cli_commands/execute", params: { plugin: "k8s_cluster", path: path, args: args, flags: flags }, as: :json
  end

  it "rejects every command for a non-admin through the same policy as the admin controllers" do
    sign_in_as(member)

    %w[clusters namespaces pods deployments services nodes pvcs events logs overview].each do |command|
      execute([ "k8s", command ], flags: command == "logs" ? { namespace: "default" } : {}, args: command == "logs" ? [ "web-1" ] : [])
      expect(response).to have_http_status(:forbidden), "#{command}: #{response.body}"
    end
  end

  it "returns the established table and text output shapes" do
    sign_in_as(admin)
    context = instance_of(McpToolContext)
    tool = K8sCluster::ClusterCredential::ADMIN_TOOL_NAME
    allow(K8sCluster::Namespaces).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::Namespaces, list: { namespaces: [ { name: "default", status: "Active" } ] }))
    allow(K8sCluster::Pods).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::Pods, list: { pods: [ { name: "web-1", namespace: "default", status: "Running", ready: "1/1", restart_count: 0, node_name: "node-1" } ] }, logs: { log: "hello\n" }))
    allow(K8sCluster::Deployments).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::Deployments, list: { deployments: [ { name: "web", namespace: "default", replicas: 1, ready_replicas: 1, available_replicas: 1, updated_replicas: 1 } ] }))
    allow(K8sCluster::Services).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::Services, list: { services: [ { name: "web", namespace: "default", type: "ClusterIP", cluster_ip: "10.0.0.1", ports: [ { port: 80, protocol: "TCP" } ] } ] }))
    allow(K8sCluster::Nodes).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::Nodes, list: { nodes: [ { name: "node-1", ready: true, roles: [ "worker" ], kubelet_version: "v1", internal_ip: "10.0.0.2" } ] }))
    allow(K8sCluster::PersistentVolumeClaims).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::PersistentVolumeClaims, list: { persistent_volume_claims: [ { name: "data", namespace: "default", status: "Bound", capacity: "1Gi", storage_class: "local" } ] }))
    allow(K8sCluster::Events).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::Events, list: { events: [ { namespace: "default", type: "Normal", reason: "Started", involved_object: { kind: "Pod", name: "web-1" }, message: "Started container" } ] }))
    allow(K8sCluster::Overview).to receive(:new).with(cluster, context: context, tool_name: tool)
      .and_return(instance_double(K8sCluster::Overview, call: { nodes: { available: false, message: "metrics unavailable" }, pods: { available: false, message: "metrics unavailable" } }))

    expectations = {
      "clusters" => [ "ID", "LABEL", "API SERVER", "AGENTIC", "WRITES" ],
      "namespaces" => [ "NAME", "STATUS" ], "pods" => [ "NAME", "NAMESPACE", "STATUS", "READY", "RESTARTS", "NODE" ],
      "deployments" => [ "NAME", "NAMESPACE", "REPLICAS", "READY", "AVAILABLE", "UPDATED" ],
      "services" => [ "NAME", "NAMESPACE", "TYPE", "CLUSTER-IP", "PORTS" ], "nodes" => [ "NAME", "READY", "ROLES", "VERSION", "INTERNAL-IP" ],
      "pvcs" => [ "NAME", "NAMESPACE", "STATUS", "CAPACITY", "STORAGE CLASS" ], "events" => [ "NAMESPACE", "TYPE", "REASON", "OBJECT", "MESSAGE" ]
    }
    expectations.each do |command, columns|
      execute([ "k8s", command ])
      expect(response).to have_http_status(:ok), "#{command}: #{response.body}"
      expect(response.parsed_body.dig("result", "columns")).to eq(columns), command
      expect(response.parsed_body.dig("result", "rows")).not_to be_empty, command
    end

    execute(%w[k8s logs], flags: { namespace: "default", tail: 200 }, args: [ "web-1" ])
    expect(response.parsed_body.dig("result", "kind")).to eq("raw_text")
    expect(response.parsed_body.dig("result", "text")).to eq("hello\n")
    execute(%w[k8s overview])
    expect(response.parsed_body.dig("result", "text")).to eq("Nodes: unavailable (metrics unavailable)\nPods: unavailable (metrics unavailable)")
  end
end
