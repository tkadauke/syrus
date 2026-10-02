module CredentialStore
  class Broker
    module TargetConstraint
      class AllowedHosts < Base
        def satisfied?(target)
          values.empty? || values.include?(target[:host].to_s)
        end

        def denial_reason = "host not allowed"
      end
    end
  end
end
