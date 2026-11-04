module Syrus
  module Plugin
    module ReviewerTargetProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def reviewer_target_type(value = nil)
          @reviewer_target_type = value.to_s if value
          @reviewer_target_type
        end
      end
    end
  end
end
