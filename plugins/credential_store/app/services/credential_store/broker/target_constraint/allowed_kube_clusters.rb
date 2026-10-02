module CredentialStore
  class Broker
    module TargetConstraint
      class AllowedKubeClusters < Base
        def satisfied?(target)
          values.empty? || values.include?(target[:kube_cluster].to_s)
        end

        def denial_reason = "kube cluster not allowed"
      end
    end
  end
end
