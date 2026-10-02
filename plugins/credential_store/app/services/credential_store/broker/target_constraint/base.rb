module CredentialStore
  class Broker
    module TargetConstraint
      class Base
        def initialize(values)
          @values = Array(values).map(&:to_s).compact_blank
        end

        def satisfied?(_target)
          raise NotImplementedError
        end

        def denial_reason
          "target not allowed"
        end

        private

        attr_reader :values
      end
    end
  end
end
