module CredentialStore
  class Broker
    module TargetConstraint
      class AllowedKubeContexts < Base
        def satisfied?(target)
          values.empty? || values.include?(target[:kube_context].to_s)
        end

        def denial_reason = "kube context not allowed"
      end
    end
  end
end
