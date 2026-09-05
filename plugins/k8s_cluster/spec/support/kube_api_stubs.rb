# Shared WebMock stubs for a fake Kubernetes API server, used by every
# K8sCluster resource service spec. Kubeclient discovers each API group's
# resources (a GET against the group's own root, e.g. `/api/v1` or
# `/apis/apps/v1`) before it will dispatch entity methods like `get_pods` -
# so every spec needs both a discovery stub and a resource-endpoint stub, the
# same two requests a real cluster would see.
module KubeApiStubs
  CORE_RESOURCES = [
    { "name" => "namespaces", "namespaced" => false, "kind" => "Namespace" },
    { "name" => "pods", "namespaced" => true, "kind" => "Pod" },
    { "name" => "pods/log", "namespaced" => true, "kind" => "Pod" },
    { "name" => "services", "namespaced" => true, "kind" => "Service" },
    { "name" => "events", "namespaced" => true, "kind" => "Event" },
    { "name" => "persistentvolumeclaims", "namespaced" => true, "kind" => "PersistentVolumeClaim" },
    { "name" => "nodes", "namespaced" => false, "kind" => "Node" }
  ].freeze

  APPS_RESOURCES = [ { "name" => "deployments", "namespaced" => true, "kind" => "Deployment" } ].freeze
  BATCH_RESOURCES = [ { "name" => "cronjobs", "namespaced" => true, "kind" => "CronJob" } ].freeze

  def stub_core_discovery(base)
    stub_discovery(base: base, path: "api/v1", group_version: "v1", resources: CORE_RESOURCES)
  end

  def stub_apps_discovery(base)
    stub_discovery(base: base, path: "apis/apps/v1", group_version: "apps/v1", resources: APPS_RESOURCES)
  end

  def stub_batch_discovery(base)
    stub_discovery(base: base, path: "apis/batch/v1", group_version: "batch/v1", resources: BATCH_RESOURCES)
  end

  def stub_discovery(base:, path:, group_version:, resources:)
    stub_request(:get, "#{base}/#{path}").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { kind: "APIResourceList", groupVersion: group_version, resources: resources }.to_json
    )
  end

  def stub_kube_get(url, body)
    stub_request(:get, url).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  def stub_kube_error(url, status)
    stub_request(:get, url).to_return(status: status, headers: { "Content-Type" => "application/json" }, body: { message: "boom" }.to_json)
  end

  def stub_kube_text(url, text)
    stub_request(:get, url).to_return(status: 200, headers: { "Content-Type" => "text/plain" }, body: text)
  end
end
