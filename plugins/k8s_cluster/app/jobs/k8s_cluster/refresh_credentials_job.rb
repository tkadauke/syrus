class K8sCluster::RefreshCredentialsJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform
    return unless K8sCluster.enabled?

    KubernetesCluster.find_each { |cluster| K8sCluster::CredentialRefresher.call(cluster) }
  end
end
