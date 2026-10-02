module CredentialStore
  class Broker
    module TargetConstraint
      class AllowedUrlPrefixes < Base
        def satisfied?(target)
          url = target[:url].to_s
          values.empty? || values.any? { |prefix| url.start_with?(prefix) }
        end

        def denial_reason = "url not allowed"
      end
    end
  end
end
