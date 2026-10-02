module CredentialStore
  class Broker
    module TargetConstraint
      class AllowedKubeNamespaces < Base
        def satisfied?(target)
          values.empty? || values.include?(target[:kube_namespace].to_s)
        end

        def denial_reason = "kube namespace not allowed"
      end
    end
  end
end
