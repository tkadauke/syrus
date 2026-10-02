module CredentialStore
  class Broker
    module TargetConstraint
      class Registry
        CONSTRAINTS = {
          "allowed_hosts" => "CredentialStore::Broker::TargetConstraint::AllowedHosts",
          "allowed_kube_clusters" => "CredentialStore::Broker::TargetConstraint::AllowedKubeClusters",
          "allowed_kube_contexts" => "CredentialStore::Broker::TargetConstraint::AllowedKubeContexts",
          "allowed_kube_namespaces" => "CredentialStore::Broker::TargetConstraint::AllowedKubeNamespaces",
          "allowed_url_prefixes" => "CredentialStore::Broker::TargetConstraint::AllowedUrlPrefixes"
        }.freeze

        def self.for(key, values)
          CONSTRAINTS.fetch(key.to_s).constantize.new(values)
        end
      end
    end
  end
end
