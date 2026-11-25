class K8sCluster::RefreshCredentialsJob < Syrus::Host::PluginJob
  plugin :k8s_cluster

  def perform
    return unless K8sCluster.enabled?

    Syrus::Host::KubernetesCluster.find_each { |cluster| K8sCluster::CredentialRefresher.call(cluster) }
  end
end
